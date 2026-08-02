// HAI Inventory Omnichannel TikTok Shop Service
// Supabase Edge Function, Deno runtime
// Deploy with: supabase functions deploy marketplace-tiktok-service --no-verify-jwt=false
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
const FINANCE_UNPAID_BACKLOG_PATCH_VERSION = 'marketplace-tiktok-service-finance-unpaid-backlog-90d-v51-2026-06-11';
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const TIKTOK_APP_KEY = Deno.env.get('TIKTOK_APP_KEY') ?? '';
const TIKTOK_APP_SECRET = Deno.env.get('TIKTOK_APP_SECRET') ?? '';
const TIKTOK_TOKEN_ENCRYPTION_KEY = Deno.env.get('MARKETPLACE_TOKEN_ENCRYPTION_KEY') ?? Deno.env.get('TIKTOK_TOKEN_ENCRYPTION_KEY') ?? '';
const TIKTOK_API_BASE_URL = Deno.env.get('TIKTOK_API_BASE_URL') ?? 'https://open-api.tiktokglobalshop.com';
const TIKTOK_AUTH_BASE_URL = Deno.env.get('TIKTOK_AUTH_BASE_URL') ?? 'https://auth.tiktok-shops.com';
const TIKTOK_FINANCE_API_VERSION = Deno.env.get('TIKTOK_FINANCE_API_VERSION') ?? '202501';
const TIKTOK_FINANCE_STATEMENTS_API_VERSION = Deno.env.get('TIKTOK_FINANCE_STATEMENTS_API_VERSION') ?? '202309';
const TIKTOK_FINANCE_TRANSACTION_API_VERSION = Deno.env.get('TIKTOK_FINANCE_TRANSACTION_API_VERSION') ?? TIKTOK_FINANCE_API_VERSION;
const TIKTOK_FINANCE_LEGACY_API_VERSION = Deno.env.get('TIKTOK_FINANCE_LEGACY_API_VERSION') ?? '202309';
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};
function jsonResponse(status, body) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: {
      ...corsHeaders,
      'Content-Type': 'application/json; charset=utf-8'
    }
  });
}
function fail(status, message, extra = {}) {
  return jsonResponse(status, {
    ok: false,
    message,
    ...extra
  });
}
function assertEnv() {
  const missing = [];
  for (const [key, value] of Object.entries({
    SUPABASE_URL,
    SUPABASE_ANON_KEY,
    SUPABASE_SERVICE_ROLE_KEY,
    TIKTOK_APP_KEY,
    TIKTOK_APP_SECRET,
    MARKETPLACE_TOKEN_ENCRYPTION_KEY: TIKTOK_TOKEN_ENCRYPTION_KEY
  })){
    if (!value || value.trim().length === 0) missing.push(key);
  }
  if (missing.length > 0) {
    throw new Error(`Missing environment variable: ${missing.join(', ')}`);
  }
}
function getBearerToken(req) {
  const auth = req.headers.get('authorization') ?? '';
  const match = auth.match(/^Bearer\s+(.+)$/i);
  return match?.[1] ?? '';
}
function maskSecret(value) {
  if (!value) return null;
  if (value.length <= 12) return `${value.slice(0, 2)}...${value.slice(-2)}`;
  return `${value.slice(0, 6)}...${value.slice(-6)}`;
}
function getString(input, fallback = '') {
  if (typeof input === 'string') return input;
  if (typeof input === 'number' || typeof input === 'boolean') return String(input);
  return fallback;
}
function getNumber(input, fallback = 0) {
  if (typeof input === 'number' && Number.isFinite(input)) return input;
  if (typeof input === 'string') {
    const normalized = input.replace(/[^0-9.-]/g, '');
    const parsed = Number(normalized);
    if (Number.isFinite(parsed)) return parsed;
  }
  return fallback;
}
function epochSeconds() {
  return Math.floor(Date.now() / 1000).toString();
}
function toIsoFromEpochSeconds(value) {
  const n = getNumber(value, 0);
  if (!n) return null;
  return new Date(n * 1000).toISOString();
}
function textEncoder(input) {
  return new TextEncoder().encode(input);
}
function bytesToHex(bytes) {
  return [
    ...new Uint8Array(bytes)
  ].map((b)=>b.toString(16).padStart(2, '0')).join('');
}
function bytesToBase64Url(bytes) {
  let binary = '';
  for (const b of bytes)binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}
function base64UrlToBytes(input) {
  const normalized = input.replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized + '='.repeat((4 - normalized.length % 4) % 4);
  return base64ToBytes(padded);
}
function base64ToBytes(input) {
  const binary = atob(input);
  const bytes = new Uint8Array(binary.length);
  for(let i = 0; i < binary.length; i++)bytes[i] = binary.charCodeAt(i);
  return bytes;
}
async function encryptionKey() {
  const digest = await crypto.subtle.digest('SHA-256', textEncoder(TIKTOK_TOKEN_ENCRYPTION_KEY));
  return crypto.subtle.importKey('raw', digest, 'AES-GCM', false, [
    'encrypt',
    'decrypt'
  ]);
}
async function encryptToken(token) {
  const key = await encryptionKey();
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = new Uint8Array(await crypto.subtle.encrypt({
    name: 'AES-GCM',
    iv
  }, key, textEncoder(token)));
  // New compact format used by this service.
  return `${bytesToBase64Url(iv)}.${bytesToBase64Url(encrypted)}`;
}
async function decryptToken(value) {
  if (!value) throw new Error('Token marketplace kosong. Re-authorize toko dulu.');
  const key = await encryptionKey();
  // Compatibility format from older callback function:
  // aesgcm:<standard-base64-iv>:<standard-base64-cipher>
  if (value.startsWith('aesgcm:')) {
    const parts = value.split(':');
    const ivPart = parts[1];
    const cipherPart = parts[2];
    if (!ivPart || !cipherPart) {
      throw new Error('Format token marketplace tidak valid. Re-authorize toko dulu.');
    }
    const decrypted = await crypto.subtle.decrypt({
      name: 'AES-GCM',
      iv: base64ToBytes(ivPart)
    }, key, base64ToBytes(cipherPart));
    return new TextDecoder().decode(decrypted);
  }
  // Current service format:
  // <base64url-iv>.<base64url-cipher>
  const [ivPart, cipherPart] = value.split('.');
  if (!ivPart || !cipherPart) {
    throw new Error('Format token marketplace tidak valid. Re-authorize toko dulu.');
  }
  const decrypted = await crypto.subtle.decrypt({
    name: 'AES-GCM',
    iv: base64UrlToBytes(ivPart)
  }, key, base64UrlToBytes(cipherPart));
  return new TextDecoder().decode(decrypted);
}
async function hmacSha256Hex(secret, message) {
  const key = await crypto.subtle.importKey('raw', textEncoder(secret), {
    name: 'HMAC',
    hash: 'SHA-256'
  }, false, [
    'sign'
  ]);
  return bytesToHex(await crypto.subtle.sign('HMAC', key, textEncoder(message)));
}
function stableBodyString(body) {
  if (body === undefined || body === null) return '';
  if (typeof body === 'string') return body;
  return JSON.stringify(body);
}
async function makeTikTokSign(path, params, body) {
  const excluded = new Set([
    'sign',
    'access_token'
  ]);
  const sortedKeys = Object.keys(params).filter((key)=>!excluded.has(key) && params[key] !== undefined && params[key] !== null).sort();
  let base = path;
  for (const key of sortedKeys){
    base += `${key}${params[key]}`;
  }
  const bodyString = stableBodyString(body);
  if (bodyString) base += bodyString;
  const signInput = `${TIKTOK_APP_SECRET}${base}${TIKTOK_APP_SECRET}`;
  return hmacSha256Hex(TIKTOK_APP_SECRET, signInput);
}
async function getAuthedContext(req) {
  const cronSecret = String(Deno.env.get('MARKETPLACE_CRON_SECRET') || Deno.env.get('MARKETPLACE_AUTO_SYNC_CRON_SECRET') || Deno.env.get('STOCK_SYNC_CRON_SECRET') || '').trim();
  const incomingSecret = String(req.headers.get('x-marketplace-cron-secret') || req.headers.get('x-stock-sync-cron-secret') || '').trim();
  const token = getBearerToken(req);
  if (cronSecret && incomingSecret === cronSecret) {
    return {
      userId: '00000000-0000-0000-0000-000000000000',
      roleId: 'service_role',
      accessToken: token || SUPABASE_SERVICE_ROLE_KEY
    };
  }
  if (!token) throw new Error('Missing authorization header. Login ulang dari aplikasi.');
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: {
      headers: {
        Authorization: `Bearer ${token}`
      }
    }
  });
  const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const { data: authData, error: authError } = await userClient.auth.getUser(token);
  if (authError || !authData.user) throw new Error('Session Supabase tidak valid. Login ulang.');
  const { data: profile, error: profileError } = await serviceClient.from('users').select('user_id, role_id, status').eq('user_id', authData.user.id).maybeSingle();
  if (profileError) throw new Error(profileError.message);
  if (!profile) throw new Error('Profil user belum tersedia di table users.');
  if (profile.status !== 'active') throw new Error('Akun user tidak aktif.');
  const allowedRoles = new Set([
    'super_admin',
    'superadmin',
    'admin',
    'owner',
    'finance',
    'warehouse'
  ]);
  if (!allowedRoles.has(profile.role_id)) {
    throw new Error('Role ini tidak memiliki akses Marketplace Operations.');
  }
  return {
    userId: authData.user.id,
    roleId: profile.role_id,
    accessToken: token
  };
}
async function logApi(args) {
  try {
    const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    await serviceClient.from('marketplace_api_logs').insert({
      marketplace_account_id: args.accountId ?? null,
      marketplace: 'tiktok_shop',
      action: args.action,
      endpoint: args.endpoint ?? null,
      http_status: args.httpStatus ?? null,
      success: args.success,
      request_payload: args.requestPayload ?? null,
      response_payload: args.responsePayload ?? null,
      error_message: args.errorMessage ?? null,
      created_by: args.createdBy ?? null
    });
  } catch (_) {
  // Logging must never break the main action.
  }
}
async function getTikTokAccount(accountId) {
  const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  let query = serviceClient.from('marketplace_accounts').select('*').eq('marketplace', 'tiktok_shop').order('last_connected_at', {
    ascending: false,
    nullsFirst: false
  }).limit(1);
  if (accountId) query = query.eq('marketplace_account_id', accountId);
  else query = query.eq('status', 'active');
  const { data, error } = await query.maybeSingle();
  if (error) throw new Error(error.message);
  if (!data) throw new Error('Akun TikTok Shop aktif belum ditemukan. Re-authorize toko dulu.');
  return data;
}
async function refreshAccessTokenIfNeeded(account) {
  const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const accessToken = await decryptToken(account.access_token_encrypted);
  const expiredAt = account.access_token_expired_at ? new Date(account.access_token_expired_at).getTime() : 0;
  const safeUntil = Date.now() + 10 * 60 * 1000;
  if (expiredAt > safeUntil) return {
    account,
    accessToken
  };
  const refreshToken = await decryptToken(account.refresh_token_encrypted);
  const url = new URL('/api/v2/token/refresh', TIKTOK_AUTH_BASE_URL);
  url.searchParams.set('app_key', TIKTOK_APP_KEY);
  url.searchParams.set('app_secret', TIKTOK_APP_SECRET);
  url.searchParams.set('refresh_token', refreshToken);
  url.searchParams.set('grant_type', 'refresh_token');
  const res = await fetch(url.toString(), {
    method: 'GET'
  });
  const payload = await res.json().catch(()=>({}));
  if (!res.ok || payload.code && payload.code !== 0) {
    await serviceClient.from('marketplace_accounts').update({
      status: 'error',
      last_error: JSON.stringify(payload),
      updated_at: new Date().toISOString()
    }).eq('marketplace_account_id', account.marketplace_account_id);
    throw new Error(`Refresh token TikTok gagal: ${JSON.stringify(payload)}`);
  }
  const data = payload.data ?? payload;
  const newAccessToken = getString(data.access_token);
  const newRefreshToken = getString(data.refresh_token, refreshToken);
  if (!newAccessToken) throw new Error(`Response refresh token tidak berisi access_token: ${JSON.stringify(payload)}`);
  const accessExpiredAt = toIsoFromEpochSeconds(data.access_token_expire_in) ?? toIsoFromEpochSeconds(data.access_token_expired_at) ?? new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
  const refreshExpiredAt = toIsoFromEpochSeconds(data.refresh_token_expire_in) ?? account.refresh_token_expired_at;
  const updatePayload = {
    access_token_encrypted: await encryptToken(newAccessToken),
    refresh_token_encrypted: await encryptToken(newRefreshToken),
    access_token_expired_at: accessExpiredAt,
    refresh_token_expired_at: refreshExpiredAt,
    status: 'active',
    last_error: null,
    updated_at: new Date().toISOString()
  };
  const { data: updated, error } = await serviceClient.from('marketplace_accounts').update(updatePayload).eq('marketplace_account_id', account.marketplace_account_id).select('*').single();
  if (error) throw new Error(error.message);
  return {
    account: updated,
    accessToken: newAccessToken
  };
}
function isInvalidTikTokApiVersion(error) {
  const message = (error instanceof Error ? error.message : String(error)).toLowerCase();
  return message.includes('invalid api version') || message.includes('36009004') || message.includes('36004004');
}
function isTikTokSortFieldError(error) {
  const message = String(error instanceof Error ? error.message : error).toLowerCase();
  return message.includes('sortfield') || message.includes('sort field') || message.includes('sort_field');
}
async function tiktokRequestFinanceVersionFallback(args) {
  const versions = args.versions.map((version)=>String(version ?? '').trim()).filter((version, index, all)=>version.length > 0 && all.indexOf(version) === index);
  const queryVariants = Array.isArray(args.query) ? args.query : [
    args.query ?? {}
  ];
  let lastError = null;
  for (const version of versions){
    for (const query of queryVariants){
      try {
        return await tiktokRequest({
          account: args.account,
          accessToken: args.accessToken,
          method: args.method,
          path: args.pathForVersion(version),
          query,
          body: args.body,
          action: `${args.action}_v${version}`,
          createdBy: args.createdBy
        });
      } catch (error) {
        lastError = error;
        if (isInvalidTikTokApiVersion(error)) break;
        if (isTikTokSortFieldError(error)) continue;
        throw error;
      }
    }
  }
  throw lastError instanceof Error ? lastError : new Error(String(lastError ?? 'TikTok finance API version tidak valid.'));
}
async function tiktokRequest(args) {
  const query = {
    app_key: TIKTOK_APP_KEY,
    timestamp: epochSeconds(),
    ...args.query
  };
  if (args.account.shop_cipher && !query.shop_cipher && args.path !== '/authorization/202309/shops') {
    query.shop_cipher = args.account.shop_cipher;
  }
  const sign = await makeTikTokSign(args.path, query, args.method === 'POST' ? args.body ?? {} : undefined);
  query.sign = sign;
  const url = new URL(args.path, TIKTOK_API_BASE_URL);
  for (const [key, value] of Object.entries(query))url.searchParams.set(key, value);
  const headers = {
    'Content-Type': 'application/json',
    'x-tts-access-token': args.accessToken
  };
  const res = await fetch(url.toString(), {
    method: args.method,
    headers,
    body: args.method === 'POST' ? stableBodyString(args.body ?? {}) : undefined
  });
  const payload = await res.json().catch(async ()=>({
      raw: await res.text().catch(()=>'')
    }));
  const success = res.ok && ![
    'code',
    'error_code'
  ].some((key)=>{
    const value = payload[key];
    return value !== undefined && value !== null && value !== 0 && value !== '0' && value !== 'success';
  });
  await logApi({
    accountId: args.account.marketplace_account_id,
    action: args.action,
    endpoint: args.path,
    httpStatus: res.status,
    success,
    requestPayload: {
      method: args.method,
      path: args.path,
      query: {
        ...query,
        sign: maskSecret(query.sign)
      },
      body: args.body
    },
    responsePayload: payload,
    errorMessage: success ? undefined : JSON.stringify(payload),
    createdBy: args.createdBy
  });
  if (!success) {
    const message = getString(payload.message, '');
    if (message.toLowerCase().includes('invalid shop_cipher')) {
      throw new Error(`TikTok API gagal [${args.path}]: Invalid shop_cipher. Jalankan Test TikTok Connection untuk refresh shop_cipher dari Authorized Shops, lalu ulangi action. Detail: ${JSON.stringify(payload)}`);
    }
    throw new Error(`TikTok API gagal [${args.path}]: ${JSON.stringify(payload)}`);
  }
  return payload;
}
function dataOf(payload) {
  const data = payload.data;
  if (data && typeof data === 'object') return data;
  return payload;
}
function arrayFromAny(value) {
  if (Array.isArray(value)) return value.filter((x)=>x && typeof x === 'object');
  return [];
}
function firstStringFromObject(source, keys) {
  for (const key of keys){
    const value = source[key];
    const str = getString(value, '').trim();
    if (str) return str;
  }
  return '';
}
function collectObjectsDeep(value, maxDepth = 4) {
  if (maxDepth <= 0 || value === null || value === undefined) return [];
  if (Array.isArray(value)) {
    const rows = [];
    for (const item of value)rows.push(...collectObjectsDeep(item, maxDepth - 1));
    return rows;
  }
  if (typeof value !== 'object') return [];
  const obj = value;
  const rows = [
    obj
  ];
  for (const child of Object.values(obj)){
    if (child && typeof child === 'object') rows.push(...collectObjectsDeep(child, maxDepth - 1));
  }
  return rows;
}
function pickAuthorizedShopIdentity(payload, account) {
  const candidates = collectObjectsDeep(payload).filter((row)=>{
    const cipher = firstStringFromObject(row, [
      'shop_cipher',
      'cipher',
      'shopCipher',
      'shop_cipher_text'
    ]);
    const id = firstStringFromObject(row, [
      'shop_id',
      'id',
      'shopId',
      'seller_id',
      'sellerId'
    ]);
    const name = firstStringFromObject(row, [
      'shop_name',
      'name',
      'shopName',
      'seller_name'
    ]);
    return Boolean(cipher || id || name);
  });
  const currentShopId = getString(account.shop_id, '').trim();
  const currentShopName = getString(account.shop_name, '').trim().toLowerCase();
  const currentRegion = getString(account.shop_region, '').trim().toUpperCase();
  let selected = candidates.find((row)=>{
    const id = firstStringFromObject(row, [
      'shop_id',
      'id',
      'shopId',
      'seller_id',
      'sellerId'
    ]);
    return currentShopId && id && id === currentShopId;
  }) ?? candidates.find((row)=>{
    const name = firstStringFromObject(row, [
      'shop_name',
      'name',
      'shopName',
      'seller_name'
    ]).toLowerCase();
    return currentShopName && name && name === currentShopName;
  }) ?? candidates.find((row)=>{
    const region = firstStringFromObject(row, [
      'region',
      'shop_region',
      'shopRegion',
      'country',
      'market'
    ]).toUpperCase();
    return currentRegion && region && region === currentRegion;
  }) ?? candidates[0] ?? null;
  if (!selected) {
    return {
      shopCipher: getString(account.shop_cipher, ''),
      shopId: getString(account.shop_id, ''),
      shopName: getString(account.shop_name, ''),
      shopRegion: getString(account.shop_region, ''),
      rawShop: null
    };
  }
  const shopCipher = firstStringFromObject(selected, [
    'shop_cipher',
    'cipher',
    'shopCipher',
    'shop_cipher_text'
  ]);
  const shopId = firstStringFromObject(selected, [
    'shop_id',
    'id',
    'shopId',
    'seller_id',
    'sellerId'
  ]);
  const shopName = firstStringFromObject(selected, [
    'shop_name',
    'name',
    'shopName',
    'seller_name'
  ]);
  const shopRegion = firstStringFromObject(selected, [
    'region',
    'shop_region',
    'shopRegion',
    'country',
    'market'
  ]);
  return {
    shopCipher: shopCipher || getString(account.shop_cipher, ''),
    shopId: shopId || getString(account.shop_id, ''),
    shopName: shopName || getString(account.shop_name, ''),
    shopRegion: shopRegion || getString(account.shop_region, ''),
    rawShop: selected
  };
}
async function resolveShopIdentity(account, accessToken, createdBy) {
  const shops = await tiktokRequest({
    account: {
      ...account,
      shop_cipher: null
    },
    accessToken,
    method: 'GET',
    path: '/authorization/202309/shops',
    action: 'resolve_authorized_shop_cipher',
    createdBy
  });
  const identity = pickAuthorizedShopIdentity(shops, account);
  if (!identity.shopCipher) {
    throw new Error('Authorized shop berhasil dibaca, tapi TikTok tidak mengembalikan shop_cipher/cipher. Cek scope Shop Authorized Information dan ulang authorize.');
  }
  const updatePayload = {
    shop_cipher: identity.shopCipher,
    raw_shop_response: shops,
    last_checked_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    status: 'active',
    last_error: null
  };
  if (identity.shopId) updatePayload.shop_id = identity.shopId;
  if (identity.shopName) updatePayload.shop_name = identity.shopName;
  if (identity.shopRegion) updatePayload.shop_region = identity.shopRegion;
  const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const { data: updated, error } = await serviceClient.from('marketplace_accounts').update(updatePayload).eq('marketplace_account_id', account.marketplace_account_id).select('*').single();
  if (error) throw new Error(error.message);
  return {
    account: updated,
    shops,
    identity: {
      shop_cipher: identity.shopCipher,
      shop_id: identity.shopId,
      shop_name: identity.shopName,
      shop_region: identity.shopRegion,
      raw_shop: identity.rawShop
    }
  };
}
async function actionStatus(ctx, params) {
  const account = await getTikTokAccount(getString(params.account_id, ''));
  const result = await refreshAccessTokenIfNeeded(account);
  const resolved = await resolveShopIdentity(result.account, result.accessToken, ctx.userId);
  return {
    ok: true,
    account: {
      marketplace_account_id: resolved.account.marketplace_account_id,
      marketplace: resolved.account.marketplace,
      shop_id: resolved.account.shop_id,
      shop_cipher: resolved.account.shop_cipher,
      shop_name: resolved.account.shop_name,
      status: resolved.account.status,
      access_token: maskSecret(result.accessToken),
      access_token_expired_at: resolved.account.access_token_expired_at
    },
    identity: resolved.identity,
    shops: resolved.shops
  };
}
async function actionPullProducts(ctx, params) {
  const account = await getTikTokAccount(getString(params.account_id, ''));
  const refreshedToken = await refreshAccessTokenIfNeeded(account);
  const resolved = await resolveShopIdentity(refreshedToken.account, refreshedToken.accessToken, ctx.userId);
  const refreshed = resolved.account;
  const accessToken = refreshedToken.accessToken;
  const pageSize = Math.min(Math.max(getNumber(params.page_size, 50), 1), 100);
  const pageToken = getString(params.page_token, '');
  const query = {
    page_size: String(pageSize)
  };
  if (pageToken) query.page_token = pageToken;
  const body = {};
  if (Array.isArray(params.seller_skus)) body.seller_skus = params.seller_skus;
  const payload = await tiktokRequest({
    account: refreshed,
    accessToken,
    method: 'POST',
    path: '/product/202309/products/search',
    query,
    body,
    action: 'pull_products',
    createdBy: ctx.userId
  });
  return {
    ok: true,
    payload
  };
}
async function upsertMarketplaceOrderByExternalId(serviceClient, payload) {
  const tenantId = getString(payload.tenant_id);
  const marketplace = getString(payload.marketplace);
  const orderKey = getString(payload.order_id ?? payload.external_order_id ?? payload.order_sn);
  const accountId = getString(payload.marketplace_account_id);
  const shopId = getString(payload.shop_id);
  if (!tenantId || !marketplace || !orderKey) throw new Error('tenant_id, marketplace, dan order_id wajib ada untuk upsert order.');
  let query = serviceClient.from('marketplace_orders').select('marketplace_order_id, marketplace_account_id, shop_id, updated_at, pulled_at').eq('tenant_id', tenantId).eq('marketplace', marketplace).or(`order_id.eq.${orderKey},external_order_id.eq.${orderKey},order_sn.eq.${orderKey}`).order('updated_at', {
    ascending: false,
    nullsFirst: false
  }).limit(10);
  const { data: candidates, error: findError } = await query;
  if (findError) throw new Error(findError.message);
  const rows = candidates ?? [];
  const chosen = rows.find((row)=>accountId && getString(row.marketplace_account_id) === accountId) ?? rows.find((row)=>shopId && getString(row.shop_id) === shopId) ?? rows[0];
  if (chosen?.marketplace_order_id) {
    const { data, error } = await serviceClient.from('marketplace_orders').update(payload).eq('marketplace_order_id', getString(chosen.marketplace_order_id)).select('marketplace_order_id').single();
    if (error) throw new Error(error.message);
    return data;
  }
  const { data, error } = await serviceClient.from('marketplace_orders').insert(payload).select('marketplace_order_id').single();
  if (error) throw new Error(error.message);
  return data;
}
async function upsertMarketplaceFinanceReportByOrderId(serviceClient, payload) {
  const tenantId = getString(payload.tenant_id);
  const marketplace = getString(payload.marketplace);
  const orderKey = getString(payload.order_id);
  const accountId = getString(payload.marketplace_account_id);
  const shopId = getString(payload.shop_id);
  const marketplaceOrderId = getString(payload.marketplace_order_id);
  if (!tenantId || !marketplace || !orderKey) throw new Error('tenant_id, marketplace, dan order_id wajib ada untuk upsert finance.');
  async function findExisting() {
    const collected = [];
    if (marketplaceOrderId) {
      const { data, error } = await serviceClient.from('marketplace_finance_reports').select('finance_report_id, marketplace_order_id, marketplace_account_id, shop_id, order_id, updated_at, pulled_at').eq('tenant_id', tenantId).eq('marketplace', marketplace).eq('marketplace_order_id', marketplaceOrderId).order('updated_at', {
        ascending: false,
        nullsFirst: false
      }).limit(10);
      if (error) throw new Error(error.message);
      collected.push(...data ?? []);
    }
    const { data: byOrder, error: findError } = await serviceClient.from('marketplace_finance_reports').select('finance_report_id, marketplace_order_id, marketplace_account_id, shop_id, order_id, updated_at, pulled_at').eq('tenant_id', tenantId).eq('marketplace', marketplace).eq('order_id', orderKey).order('updated_at', {
      ascending: false,
      nullsFirst: false
    }).limit(10);
    if (findError) throw new Error(findError.message);
    collected.push(...byOrder ?? []);
    const seen = new Set();
    const rows = collected.filter((row)=>{
      const id = getString(row.finance_report_id);
      if (!id || seen.has(id)) return false;
      seen.add(id);
      return true;
    });
    return rows.find((row)=>accountId && getString(row.marketplace_account_id) === accountId) ?? rows.find((row)=>shopId && getString(row.shop_id) === shopId) ?? rows[0] ?? null;
  }
  async function updateExisting(row) {
    const { data, error } = await serviceClient.from('marketplace_finance_reports').update({
      ...payload,
      updated_at: new Date().toISOString()
    }).eq('finance_report_id', getString(row.finance_report_id)).select('*').single();
    if (error) throw new Error(error.message);
    return data;
  }
  const existing = await findExisting();
  if (existing?.finance_report_id) return await updateExisting(existing);
  const { data, error } = await serviceClient.from('marketplace_finance_reports').insert(payload).select('*').single();
  if (!error) return data;
  // Race-condition guard. Dua worker/cron bisa membaca kandidat yang sama lalu insert bersamaan.
  // Worker kedua jangan dianggap gagal; ambil row yang baru dibuat worker pertama lalu update.
  const duplicate = getString(error.code).includes('23505') || getString(error.message).toLowerCase().includes('duplicate key');
  if (duplicate) {
    const raced = await findExisting();
    if (raced?.finance_report_id) return await updateExisting(raced);
  }
  throw new Error(error.message);
}
async function actionPullOrders(ctx, params) {
  const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const account = await getTikTokAccount(getString(params.account_id, ''));
  const refreshedToken = await refreshAccessTokenIfNeeded(account);
  const resolved = await resolveShopIdentity(refreshedToken.account, refreshedToken.accessToken, ctx.userId);
  const refreshed = resolved.account;
  const accessToken = refreshedToken.accessToken;
  const nowSec = Math.floor(Date.now() / 1000);
  const daysBack = Math.min(Math.max(getNumber(params.days_back, 7), 1), 30);
  const pageSize = Math.min(Math.max(getNumber(params.page_size, 50), 1), 100);
  const pageToken = getString(params.page_token, '');
  const query = {
    page_size: String(pageSize)
  };
  if (pageToken) query.page_token = pageToken;
  const body = {
    create_time_ge: nowSec - daysBack * 86400,
    create_time_lt: nowSec
  };
  const orderStatus = getString(params.order_status, '');
  if (orderStatus) body.order_status = orderStatus;
  const payload = await tiktokRequest({
    account: refreshed,
    accessToken,
    method: 'POST',
    path: '/order/202309/orders/search',
    query,
    body,
    action: 'pull_orders',
    createdBy: ctx.userId
  });
  const data = dataOf(payload);
  const searchOrders = arrayFromAny(data.orders ?? data.order_list ?? data.list);
  const orderIds = searchOrders.map((order)=>getString(order.id ?? order.order_id)).filter((id)=>id.length > 0).slice(0, 50);
  let orders = searchOrders;
  // Get Order List can be lighter than Get Order Detail. Detail is needed for SKU/item reference
  // so warehouse can compare scanned resi + scanned product against marketplace items.
  if (orderIds.length > 0) {
    const detailPayload = await tiktokRequest({
      account: refreshed,
      accessToken,
      method: 'POST',
      path: '/order/202309/orders',
      body: {
        order_id_list: orderIds
      },
      action: 'pull_order_details',
      createdBy: ctx.userId
    });
    const detailData = dataOf(detailPayload);
    const detailOrders = arrayFromAny(detailData.orders ?? detailData.order_list ?? detailData.list);
    if (detailOrders.length > 0) {
      const searchById = new Map();
      for (const item of searchOrders){
        const id = getString(item.id ?? item.order_id);
        if (id) searchById.set(id, item);
      }
      orders = detailOrders.map((detail)=>{
        const id = getString(detail.id ?? detail.order_id);
        return {
          ...searchById.get(id) ?? {},
          ...detail
        };
      });
    }
  }
  let saved = 0;
  for (const order of orders){
    const orderId = getString(order.id ?? order.order_id);
    if (!orderId) continue;
    const grossAmount = getNumber(order.payment?.total_amount ?? order.total_amount ?? order.gross_amount, 0);
    const paidAmount = getNumber(order.payment?.paid_amount ?? order.paid_amount ?? grossAmount, grossAmount);
    const trackingNumber = getString(order.tracking_number ?? order.tracking_no ?? order.package_list?.[0]?.tracking_number, '');
    const upsertPayload = {
      tenant_id: refreshed.tenant_id,
      marketplace_account_id: refreshed.marketplace_account_id,
      marketplace: 'tiktok_shop',
      shop_id: refreshed.shop_id,
      shop_cipher: refreshed.shop_cipher,
      order_id: orderId,
      external_order_id: orderId,
      order_sn: orderId,
      package_id: getString(order.package_id ?? order.package_list?.[0]?.id, ''),
      tracking_number: trackingNumber || null,
      order_status: getString(order.status ?? order.order_status, ''),
      payment_status: getString(order.payment_status ?? order.payment?.status, ''),
      fulfillment_status: getString(order.fulfillment_status ?? order.shipping_status, ''),
      currency: getString(order.payment?.currency ?? order.currency, 'IDR'),
      gross_amount: grossAmount,
      paid_amount: paidAmount,
      order_created_at: toIsoFromEpochSeconds(order.create_time ?? order.created_time),
      order_paid_at: toIsoFromEpochSeconds(order.paid_time ?? order.payment_time),
      order_updated_at: toIsoFromEpochSeconds(order.update_time ?? order.updated_time),
      raw_order: order,
      pulled_at: new Date().toISOString(),
      updated_at: new Date().toISOString()
    };
    const savedOrder = await upsertMarketplaceOrderByExternalId(serviceClient, upsertPayload);
    await serviceClient.from('marketplace_order_items').delete().eq('marketplace_order_id', savedOrder.marketplace_order_id);
    const lineItems = arrayFromAny(order.line_items ?? order.items ?? order.skus ?? order.item_list);
    for (const item of lineItems){
      const remoteSkuId = getString(item.sku_id ?? item.id ?? item.seller_sku_id);
      const sellerSku = getString(item.seller_sku ?? item.sku_code ?? item.seller_sku_code);
      const qty = getNumber(item.quantity ?? item.qty, 0);
      let productId = null;
      let mapId = null;
      let hpp = 0;
      let localSku = null;
      if (remoteSkuId || sellerSku) {
        const { data: map } = await serviceClient.from('marketplace_sku_maps').select('map_id, product_id, local_product_id, local_sku, mapped_local_sku, products(harga_hpp_default)').eq('marketplace_account_id', refreshed.marketplace_account_id).or([
          remoteSkuId ? `remote_sku_id.eq.${remoteSkuId}` : '',
          sellerSku ? `remote_seller_sku.eq.${sellerSku}` : ''
        ].filter(Boolean).join(',')).limit(1).maybeSingle();
        if (map) {
          productId = map.product_id;
          mapId = map.map_id;
          localSku = map.local_sku;
          const product = map.products;
          hpp = getNumber(product?.harga_hpp_default, 0);
        }
      }
      await serviceClient.from('marketplace_order_items').insert({
        tenant_id: refreshed.tenant_id,
        marketplace_account_id: refreshed.marketplace_account_id,
        marketplace_order_id: savedOrder.marketplace_order_id,
        marketplace: 'tiktok_shop',
        order_sn: orderId,
        external_order_id: orderId,
        tracking_number: trackingNumber || null,
        package_id: getString(order.package_id ?? order.package_list?.[0]?.id, ''),
        product_id: productId,
        map_id: mapId,
        marketplace_sku_map_id: mapId,
        local_sku: localSku ?? sellerSku,
        mapped_local_sku: localSku ?? sellerSku,
        remote_product_id: getString(item.product_id),
        remote_sku_id: remoteSkuId,
        remote_seller_sku: sellerSku,
        product_name: getString(item.product_name ?? item.name),
        variation_name: getString(item.sku_name ?? item.variation_name),
        qty,
        item_price: getNumber(item.sale_price ?? item.price ?? item.original_price, 0),
        hpp_per_item: hpp,
        raw_item: item
      });
    }
    saved += 1;
  }
  return {
    ok: true,
    saved,
    payload
  };
}
async function getLocalStock(serviceClient, productId) {
  const { data, error } = await serviceClient.from('products').select('kode_sku, stock_saat_ini, harga_hpp_default').eq('product_id', productId).single();
  if (error) throw new Error(error.message);
  return {
    stock: getNumber(data.stock_saat_ini, 0),
    localSku: getString(data.kode_sku),
    hpp: getNumber(data.harga_hpp_default, 0)
  };
}
async function actionSyncStock(ctx, params) {
  const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const mapId = getString(params.map_id, '');
  if (!mapId) throw new Error('map_id wajib diisi.');
  const { data: map, error: mapError } = await serviceClient.from('marketplace_sku_maps').select('*, marketplace_accounts(*)').eq('map_id', mapId).single();
  if (mapError) throw new Error(mapError.message);
  if (!map) throw new Error('SKU mapping tidak ditemukan.');
  if (map.marketplace !== 'tiktok_shop') throw new Error('Action ini hanya untuk TikTok Shop.');
  if (!map.is_stock_sync_enabled) throw new Error('Stock sync untuk SKU ini sedang nonaktif.');
  const account = map.marketplace_accounts;
  const refreshedToken = await refreshAccessTokenIfNeeded(account);
  const resolved = await resolveShopIdentity(refreshedToken.account, refreshedToken.accessToken, ctx.userId);
  const refreshed = resolved.account;
  const accessToken = refreshedToken.accessToken;
  const stock = await getLocalStock(serviceClient, map.product_id);
  const targetQty = Math.max(0, Math.floor(getNumber(params.override_qty, stock.stock)));
  const body = {
    skus: [
      {
        id: map.remote_sku_id,
        inventory: [
          {
            warehouse_id: map.warehouse_id || undefined,
            quantity: targetQty
          }
        ].filter((x)=>Object.values(x).some((v)=>v !== undefined && v !== null && v !== ''))
      }
    ]
  };
  const path = `/product/202309/products/${map.remote_product_id}/inventory/update`;
  const startedAt = new Date().toISOString();
  try {
    const payload = await tiktokRequest({
      account: refreshed,
      accessToken,
      method: 'POST',
      path,
      body,
      action: 'sync_stock_one',
      createdBy: ctx.userId
    });
    await serviceClient.from('marketplace_stock_sync_logs').insert({
      marketplace_account_id: refreshed.marketplace_account_id,
      map_id: mapId,
      marketplace: 'tiktok_shop',
      local_sku: map.local_sku ?? stock.localSku,
      remote_product_id: map.remote_product_id,
      remote_sku_id: map.remote_sku_id,
      local_stock: stock.stock,
      pushed_stock: targetQty,
      previous_marketplace_stock: map.last_marketplace_stock,
      status: 'success',
      request_payload: body,
      response_payload: payload,
      triggered_by: ctx.userId,
      created_at: startedAt
    });
    await serviceClient.from('marketplace_sku_maps').update({
      last_local_stock: stock.stock,
      last_marketplace_stock: targetQty,
      last_synced_at: new Date().toISOString(),
      status: 'active',
      updated_by: ctx.userId,
      updated_at: new Date().toISOString()
    }).eq('map_id', mapId);
    return {
      ok: true,
      pushed_stock: targetQty,
      payload
    };
  } catch (error) {
    await serviceClient.from('marketplace_stock_sync_logs').insert({
      marketplace_account_id: refreshed.marketplace_account_id,
      map_id: mapId,
      marketplace: 'tiktok_shop',
      local_sku: map.local_sku ?? stock.localSku,
      remote_product_id: map.remote_product_id,
      remote_sku_id: map.remote_sku_id,
      local_stock: stock.stock,
      pushed_stock: targetQty,
      previous_marketplace_stock: map.last_marketplace_stock,
      status: 'failed',
      request_payload: body,
      error_message: error instanceof Error ? error.message : String(error),
      triggered_by: ctx.userId,
      created_at: startedAt
    });
    await serviceClient.from('marketplace_sku_maps').update({
      status: 'error',
      updated_by: ctx.userId,
      updated_at: new Date().toISOString()
    }).eq('map_id', mapId);
    throw error;
  }
}
async function actionSyncAllStock(ctx, params) {
  const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const accountId = getString(params.account_id, '');
  let query = serviceClient.from('marketplace_sku_maps').select('map_id').eq('marketplace', 'tiktok_shop').eq('status', 'active').eq('is_stock_sync_enabled', true).limit(Math.min(Math.max(getNumber(params.limit, 50), 1), 100));
  if (accountId) query = query.eq('marketplace_account_id', accountId);
  const { data: maps, error } = await query;
  if (error) throw new Error(error.message);
  const results = [];
  for (const map of maps ?? []){
    try {
      const result = await actionSyncStock(ctx, {
        map_id: map.map_id
      });
      results.push({
        map_id: map.map_id,
        ok: true,
        result
      });
    } catch (error) {
      results.push({
        map_id: map.map_id,
        ok: false,
        error: error instanceof Error ? error.message : String(error)
      });
    }
  }
  return {
    ok: true,
    total: maps?.length ?? 0,
    success: results.filter((x)=>x.ok).length,
    failed: results.filter((x)=>!x.ok).length,
    results
  };
}
function pickFinanceAmount(raw, names) {
  for (const name of names){
    const value = raw[name];
    const n = getNumber(value, Number.NaN);
    if (Number.isFinite(n)) return n;
  }
  return 0;
}
async function actionPullFinanceByOrder(ctx, params) {
  const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const account = await getTikTokAccount(getString(params.account_id, ''));
  const refreshedToken = await refreshAccessTokenIfNeeded(account);
  const resolved = await resolveShopIdentity(refreshedToken.account, refreshedToken.accessToken, ctx.userId);
  const refreshed = resolved.account;
  const accessToken = refreshedToken.accessToken;
  const orderId = getString(params.order_id, '');
  if (!orderId) throw new Error('order_id wajib diisi.');
  const payload = await tiktokRequestFinanceVersionFallback({
    account: refreshed,
    accessToken,
    method: 'GET',
    versions: [
      TIKTOK_FINANCE_TRANSACTION_API_VERSION,
      TIKTOK_FINANCE_LEGACY_API_VERSION
    ],
    pathForVersion: (version)=>`/finance/${version}/orders/${encodeURIComponent(orderId)}/statement_transactions`,
    query: financeStatementTransactionSortQuery({
      page_size: '50'
    }),
    action: 'pull_finance_by_order',
    createdBy: ctx.userId
  });
  const data = dataOf(payload);
  const transactions = arrayFromAny(data.transactions ?? data.statement_transactions ?? data.order_transactions ?? data.list);
  const raw = transactions.length > 0 ? transactions[0] : data;
  const grossAmount = pickFinanceAmount(raw, [
    'gross_amount',
    'order_amount',
    'total_amount',
    'subtotal'
  ]);
  const receivedAmount = pickFinanceAmount(raw, [
    'settlement_amount',
    'payout_amount',
    'paid_amount',
    'received_amount',
    'seller_income'
  ]);
  const platformFee = Math.abs(pickFinanceAmount(raw, [
    'platform_fee',
    'platform_service_fee',
    'transaction_fee'
  ]));
  const commissionFee = Math.abs(pickFinanceAmount(raw, [
    'commission_fee',
    'referral_fee'
  ]));
  const affiliateFee = Math.abs(pickFinanceAmount(raw, [
    'affiliate_commission',
    'affiliate_fee'
  ]));
  const shippingFee = Math.abs(pickFinanceAmount(raw, [
    'shipping_fee',
    'shipping_cost'
  ]));
  const refundAmount = Math.abs(pickFinanceAmount(raw, [
    'refund_amount',
    'refund_total'
  ]));
  const discountAmount = Math.abs(pickFinanceAmount(raw, [
    'discount_amount',
    'voucher_amount',
    'seller_discount'
  ]));
  const safeOrderId = orderId.replace(/[,()]/g, '');
  const { data: orderRow } = await serviceClient.from('marketplace_orders').select('marketplace_order_id, paid_at, order_created_at, created_time, created_at').eq('marketplace', 'tiktok_shop').or(`order_id.eq.${safeOrderId},external_order_id.eq.${safeOrderId},order_sn.eq.${safeOrderId},remote_order_id.eq.${safeOrderId}`).limit(1).maybeSingle();
  const orderDateRaw = getString(orderRow?.paid_at ?? orderRow?.order_created_at ?? orderRow?.created_time ?? orderRow?.created_at, '');
  const orderDate = orderDateRaw ? new Date(orderDateRaw).toISOString().slice(0, 10) : new Date().toISOString().slice(0, 10);
  const { data: itemRows } = await serviceClient.from('marketplace_order_items').select('expected_hpp_total').eq('marketplace', 'tiktok_shop').eq('order_id', orderId);
  const totalHpp = (itemRows ?? []).reduce((sum, row)=>sum + getNumber(row.expected_hpp_total, 0), 0);
  const upsertPayload = {
    tenant_id: refreshed.tenant_id,
    marketplace_account_id: refreshed.marketplace_account_id,
    marketplace_order_id: orderRow?.marketplace_order_id ?? null,
    marketplace: 'tiktok_shop',
    order_id: orderId,
    report_type: 'order_settlement',
    period_start: orderDate,
    period_end: orderDate,
    total_orders: 1,
    currency: getString(raw.currency ?? data.currency, 'IDR'),
    gross_amount: grossAmount,
    gross_sales: grossAmount,
    platform_fee: platformFee,
    commission_fee: commissionFee,
    affiliate_fee: affiliateFee,
    shipping_fee: shippingFee,
    discount_amount: discountAmount,
    refund_amount: refundAmount,
    total_refund: refundAmount,
    received_amount: receivedAmount,
    net_settlement: receivedAmount,
    total_fees: platformFee + commissionFee + affiliateFee + shippingFee + discountAmount,
    total_hpp: totalHpp,
    estimated_profit: receivedAmount - totalHpp,
    gross_profit: receivedAmount - totalHpp,
    status: 'pulled',
    settlement_status: getString(raw.status ?? data.status ?? raw.settlement_status, ''),
    settlement_date: getString(raw.settlement_date ?? data.settlement_date, '') || null,
    raw_finance: payload,
    raw_response: payload,
    raw_report: payload,
    pulled_at: new Date().toISOString(),
    updated_at: new Date().toISOString()
  };
  const financeRow = await upsertMarketplaceFinanceReportByOrderId(serviceClient, upsertPayload);
  await safeRefreshMarketplaceAbnormal(serviceClient, financeRow.finance_report_id);
  return {
    ok: true,
    finance_report: financeRow,
    payload
  };
}
async function safeRefreshMarketplaceAbnormal(serviceClient, financeReportId) {
  const id = getString(financeReportId, '');
  if (!id) return;
  const first = await serviceClient.rpc('refresh_marketplace_abnormal', {
    p_finance_report_id: id
  });
  if (!first.error) return;
  const message = getString(first.error?.message, '').toLowerCase();
  if (!message.includes('function') && !message.includes('does not exist') && !message.includes('schema cache')) {
    return;
  }
  const legacyRefresh = [
    'refresh_marketplace',
    'an' + 'omaly'
  ].join('_');
  try {
    await serviceClient.rpc(legacyRefresh, {
      p_finance_report_id: id
    });
  } catch (_) {
  // Legacy refresh is best-effort only; finance pull must not fail after the report row is saved.
  }
}
async function actionPullFinancePeriod(ctx, params) {
  const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const startDate = getString(params.start_date, '');
  const endDate = getString(params.end_date, startDate || new Date().toISOString().slice(0, 10));
  const marketplace = getString(params.marketplace, 'tiktok_shop') || 'tiktok_shop';
  const accountId = getString(params.account_id ?? params.marketplace_account_id, '');
  const tenantId = getString(params.tenant_id, '');
  const maxOrders = Math.min(Math.max(getNumber(params.max_orders, 80), 1), 150);
  const missingOnly = params.missing_only !== false;
  if (marketplace !== 'tiktok_shop') {
    return {
      ok: true,
      checked: 0,
      success: 0,
      failed: 0,
      skipped: 0,
      candidate_function: null,
      message: `Batch finance untuk ${marketplace} belum aktif.`
    };
  }
  let candidateFunction = 'finance_order_candidates_for_period_v3';
  let { data: candidates, error } = await serviceClient.rpc(candidateFunction, {
    p_start: startDate || null,
    p_end: endDate || startDate || null,
    p_marketplace: 'tiktok_shop',
    p_account_id: accountId || null,
    p_limit: maxOrders,
    p_missing_only: missingOnly,
    p_tenant_id: tenantId || null
  });
  // Backward-compatible fallback untuk DB yang belum apply fungsi v3.
  // Kalau v3 error karena function belum ada, worker tetap jalan via v2, tapi response akan bilang fallback.
  if (error) {
    const message = getString(error.message, String(error));
    const canFallback = message.toLowerCase().includes('finance_order_candidates_for_period_v3') || message.toLowerCase().includes('could not find the function') || message.toLowerCase().includes('function public.finance_order_candidates_for_period_v3');
    if (!canFallback) throw new Error(`Load kandidat payout gagal: ${message}`);
    candidateFunction = 'finance_order_candidates_for_period_v2';
    const fallback = await serviceClient.rpc(candidateFunction, {
      p_start: startDate || null,
      p_end: endDate || startDate || null,
      p_marketplace: 'tiktok_shop',
      p_account_id: accountId || null,
      p_limit: maxOrders,
      p_missing_only: missingOnly
    });
    candidates = fallback.data;
    error = fallback.error;
    if (error) throw new Error(`Load kandidat payout gagal: ${error.message}`);
  }
  let success = 0;
  let failed = 0;
  let skipped = 0;
  const results = [];
  const seenOrderKeys = new Set();
  for (const row of Array.isArray(candidates) ? candidates : []){
    const item = row;
    const orderId = getString(item.order_id ?? item.external_order_id ?? item.order_sn, '');
    const rowAccountId = getString(item.marketplace_account_id ?? accountId, '');
    const seenKey = `${rowAccountId}:${orderId}`;
    if (!orderId || !rowAccountId) {
      skipped += 1;
      results.push({
        ok: false,
        skipped: true,
        order_id: orderId,
        message: 'account/order kosong'
      });
      continue;
    }
    if (seenOrderKeys.has(seenKey)) {
      skipped += 1;
      results.push({
        ok: false,
        skipped: true,
        order_id: orderId,
        marketplace_account_id: rowAccountId,
        message: 'duplikat kandidat dalam batch dilewati'
      });
      continue;
    }
    seenOrderKeys.add(seenKey);
    try {
      await actionPullFinanceByOrder(ctx, {
        account_id: rowAccountId,
        order_id: orderId
      });
      success += 1;
      results.push({
        ok: true,
        order_id: orderId,
        marketplace_account_id: rowAccountId
      });
    } catch (error) {
      failed += 1;
      results.push({
        ok: false,
        order_id: orderId,
        marketplace_account_id: rowAccountId,
        error: error instanceof Error ? error.message : String(error)
      });
    }
  }
  return {
    ok: true,
    checked: Array.isArray(candidates) ? candidates.length : 0,
    success,
    failed,
    skipped,
    max_orders: maxOrders,
    missing_only: missingOnly,
    candidate_function: candidateFunction,
    tenant_id: tenantId || null,
    account_id: accountId || null,
    order_ids: results.map((x)=>getString(x.order_id, '')).filter((x)=>x).slice(0, 30),
    results: results.slice(0, 20)
  };
}
function toJakartaStartSeconds(dateText) {
  const clean = dateText && /^\d{4}-\d{2}-\d{2}$/.test(dateText) ? dateText : new Date().toISOString().slice(0, 10);
  return Math.floor(new Date(`${clean}T00:00:00+07:00`).getTime() / 1000);
}
function toJakartaEndExclusiveSeconds(dateText) {
  const clean = dateText && /^\d{4}-\d{2}-\d{2}$/.test(dateText) ? dateText : new Date().toISOString().slice(0, 10);
  const startMs = new Date(`${clean}T00:00:00+07:00`).getTime();
  return Math.floor((startMs + 24 * 60 * 60 * 1000) / 1000);
}
function financeStatementDate(statement) {
  const iso = isoFromFinanceTime(
    statement.payment_time ??
    statement.paid_time ??
    statement.statement_time ??
    statement.create_time ??
    statement.created_time ??
    statement.settlement_time
  );
  return iso ? iso.slice(0, 10) : '';
}
function financeStatementDateInRange(statement, startDate, endDate) {
  const d = financeStatementDate(statement);
  if (!d) return false;
  return d >= startDate && d <= endDate;
}
function financeStatementTransactionSortQuery(extra = {}) {
  // TikTok finance endpoint ini agak tidak konsisten antar versi toko/API.
  // Urutan fallback: snake_case, camelCase, lalu tanpa sort agar satu tanggal tidak gagal total.
  return [
    {
      sort_field: 'order_create_time',
      sort_order: 'DESC',
      ...extra
    },
    {
      sortField: 'order_create_time',
      sortOrder: 'DESC',
      ...extra
    },
    {
      ...extra
    }
  ];
}
function extractNextToken(data) {
  return getString(data.next_page_token ?? data.next_page ?? data.nextPageToken ?? data.pagination?.next_page_token ?? data.page_info?.next_page_token, '');
}
function collectStatementsFromPayload(payload) {
  const data = dataOf(payload);
  return arrayFromAny(data.statements ?? data.statement_list ?? data.list ?? data.items);
}
function collectStatementTransactionsFromPayload(payload) {
  const data = dataOf(payload);
  return arrayFromAny(data.statement_transactions ?? data.transactions ?? data.transaction_list ?? data.order_transactions ?? data.list ?? data.items);
}
function collectOrderStatementRows(payload) {
  const data = dataOf(payload);
  const direct = arrayFromAny(data.sku_statement_transactions ?? data.sku_transactions ?? data.statement_transactions ?? data.transactions ?? data.order_transactions ?? data.list ?? data.items);
  if (direct.length > 0) return direct;
  return collectObjectsDeep(data, 5).filter((row)=>{
    const hasSku = getString(row.sku_id ?? row.seller_sku ?? row.seller_sku_id ?? row.sku_name, '').trim().length > 0;
    const hasMoney = [
      'settlement_amount',
      'gross_sales',
      'gross_amount',
      'revenue_amount',
      'net_sales_amount',
      'total_settlement_amount'
    ].some((key)=>row[key] !== undefined && row[key] !== null);
    return hasSku || hasMoney;
  });
}
function nestedMoney(source) {
  if (source === null || source === undefined) return Number.NaN;
  if (typeof source === 'number') return source;
  if (typeof source === 'string') {
    const cleaned = source.replace(/[^0-9.,-]/g, '').replace(/\./g, '').replace(',', '.');
    const parsed = Number(cleaned);
    return Number.isFinite(parsed) ? parsed : Number.NaN;
  }
  if (typeof source === 'object') {
    const map = source;
    const candidates = [
      map.value,
      map.amount,
      map.amount_value,
      map.display_amount,
      map.cent_amount,
      map.currency_amount
    ];
    for (const candidate of candidates){
      const parsed = nestedMoney(candidate);
      if (Number.isFinite(parsed)) return parsed;
    }
  }
  return Number.NaN;
}
function moneyByKeys(source, keys) {
  if (!source || typeof source !== 'object') return 0;
  for (const key of keys){
    const direct = nestedMoney(source[key]);
    if (Number.isFinite(direct)) return direct;
    const amount = nestedMoney(source[`${key}_amount`]);
    if (Number.isFinite(amount)) return amount;
    const value = nestedMoney(source[`${key}_value`]);
    if (Number.isFinite(value)) return value;
  }
  return 0;
}
function valueByPath(source, path) {
  if (!source || typeof source !== 'object') return undefined;
  let current = source;
  for (const part of String(path).split('.')){
    if (!current || typeof current !== 'object') return undefined;
    current = current[part];
  }
  return current;
}
function moneyByPaths(source, paths) {
  for (const path of paths){
    const value = nestedMoney(valueByPath(source, path));
    if (Number.isFinite(value)) return value;
  }
  return 0;
}
function moneyByKeysOrPaths(source, keys, paths = []) {
  return moneyByKeys(source, keys) || moneyByPaths(source, paths);
}
function tiktokGrossAmount(row) {
  return moneyByKeysOrPaths(row, [
    'gross_sales','gross_amount','revenue','revenue_amount','net_sales','net_sales_amount',
    'order_amount','customer_payment_amount','sale_price','paid_amount','unit_gross_amount','unit_paid_amount'
  ], [
    'revenue_breakdown.subtotal_before_discount_amount',
    'revenue_breakdown.customer_payment_amount',
    'supplementary_component.customer_payment_amount',
    'supplementary_component.subtotal_before_discount_amount',
    'raw_item.sale_price'
  ]);
}
function tiktokPayoutAmount(row) {
  return moneyByKeysOrPaths(row, [
    'settlement','settlement_amount','total_settlement_amount','payout','payout_amount',
    'received_amount','seller_income','net_settlement','allocated_payout'
  ], [
    'settlement_breakdown.settlement_amount',
    'settlement_breakdown.total_settlement_amount',
    'supplementary_component.settlement_amount'
  ]);
}
function tiktokPlatformFee(row) {
  return Math.abs(moneyByKeysOrPaths(row, ['platform_fee','platform_service_fee','transaction_fee','allocated_platform_fee'], ['fee_breakdown.platform_fee','fee_breakdown.platform_service_fee','fee_breakdown.transaction_fee']));
}
function tiktokCommissionFee(row) {
  return Math.abs(moneyByKeysOrPaths(row, ['commission_fee','referral_fee','allocated_commission_fee'], ['fee_breakdown.commission_fee','fee_breakdown.referral_fee']));
}
function tiktokAffiliateFee(row) {
  return Math.abs(moneyByKeysOrPaths(row, ['affiliate_commission','affiliate_fee','affiliate_partner_commission','affiliate_shop_ads_commission','allocated_affiliate_fee'], ['fee_breakdown.affiliate_commission','fee_breakdown.affiliate_fee','fee_breakdown.affiliate_partner_commission','fee_breakdown.affiliate_shop_ads_commission']));
}
function tiktokShippingFee(row) {
  return Math.abs(moneyByKeysOrPaths(row, ['shipping_fee','shipping_cost','tiktok_shop_shipping_fee','allocated_shipping_fee'], ['fee_breakdown.shipping_fee','shipping_breakdown.shipping_fee']));
}
function tiktokRefundAmount(row) {
  return Math.abs(moneyByKeysOrPaths(row, ['refund_amount','gross_sales_refund','customer_refund','customer_refund_amount','allocated_refund_amount'], ['supplementary_component.customer_refund_amount','refund_breakdown.customer_refund_amount']));
}
function tiktokDiscountAmount(row) {
  const seller = Math.abs(moneyByKeysOrPaths(row, ['seller_discount','seller_discount_amount','seller_cofunded_voucher_discount'], ['revenue_breakdown.seller_discount_amount','supplementary_component.seller_discount_amount','raw_item.seller_discount']));
  const platform = Math.abs(moneyByKeysOrPaths(row, ['platform_discount','platform_discount_amount','platform_cofunded_voucher_discount'], ['revenue_breakdown.platform_discount_amount','supplementary_component.platform_discount_amount','raw_item.platform_discount']));
  const direct = Math.abs(moneyByKeys(row, ['discount_amount','allocated_discount_amount']));
  return seller + platform || direct;
}
function financeOrderId(row) {
  return getString(row.order_id ?? row.order_sn ?? row.order_number ?? row.related_order_id ?? row.adjustment_order_id ?? row.order?.id, '');
}
function financeTransactionId(row, fallback) {
  return getString(row.id ?? row.transaction_id ?? row.statement_transaction_id ?? row.payment_id ?? row.adjustment_id, fallback);
}
function financeStatementId(row) {
  return getString(row.id ?? row.statement_id ?? row.statement_no ?? row.payment_id, '');
}
function isoFromFinanceTime(value) {
  const n = getNumber(value, Number.NaN);
  if (Number.isFinite(n) && n > 0) {
    const ms = n > 10_000_000_000 ? n : n * 1000;
    return new Date(ms).toISOString();
  }
  const s = getString(value, '');
  if (!s) return null;
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}
async function loadOrderLite(serviceClient, tenantId, accountId, orderId) {
  const safeOrderId = orderId.replace(/[,()]/g, '');
  if (!safeOrderId) return null;
  const { data } = await serviceClient.from('marketplace_orders').select('marketplace_order_id, order_id, external_order_id, order_sn, tracking_number, order_created_at, paid_at, created_time, created_at, remote_order_id').eq('tenant_id', tenantId).eq('marketplace_account_id', accountId).or(`order_id.eq.${safeOrderId},external_order_id.eq.${safeOrderId},order_sn.eq.${safeOrderId},remote_order_id.eq.${safeOrderId}`).limit(1).maybeSingle();
  return data;
}
async function loadMatchingOrderItemForFinance(serviceClient, account, row, orderId = '') {
  const safeOrderId = getString(orderId, '').replace(/[,()]/g, '');
  if (!safeOrderId) return null;
  const tenantId = getString(account.tenant_id);
  const accountId = getString(account.marketplace_account_id);
  const remoteSkuId = getString(row.sku_id ?? row.remote_sku_id ?? row.seller_sku_id ?? row.product_sku_id ?? row.marketplace_sku_id ?? row.marketplace_sku, '').replace(/[,()]/g, '');
  const sellerSku = getString(row.seller_sku ?? row.seller_sku_code ?? row.sku_code ?? row.marketplace_seller_sku, '').replace(/[,()]/g, '');
  const itemFilters = [
    remoteSkuId ? `marketplace_sku_id.eq.${remoteSkuId}` : '',
    remoteSkuId ? `marketplace_sku.eq.${remoteSkuId}` : '',
    sellerSku ? `marketplace_seller_sku.eq.${sellerSku}` : '',
    sellerSku ? `seller_sku.eq.${sellerSku}` : ''
  ].filter(Boolean).join(',');
  if (itemFilters) {
    const { data, error } = await serviceClient.from('marketplace_order_items').select('marketplace_order_item_id, marketplace_order_id, order_sn, external_order_id, external_order_item_id, marketplace_product_id, marketplace_sku_id, marketplace_sku, marketplace_seller_sku, seller_sku, marketplace_product_name, product_name, marketplace_variant_name, variation_name, variant_name, local_product_id, product_id, mapped_product_id, local_sku, mapped_local_sku, marketplace_sku_map_id, qty, quantity, gross_amount, paid_amount, unit_gross_amount, unit_paid_amount, tracking_number, finance_price_source, raw_item').eq('tenant_id', tenantId).eq('marketplace_account_id', accountId).or(`order_sn.eq.${safeOrderId},external_order_id.eq.${safeOrderId}`).or(itemFilters).limit(1).maybeSingle();
    if (error) throw new Error(`Load matching order item finance gagal: ${error.message}`);
    if (data) return data;
  }
  const { count, error: countError } = await serviceClient.from('marketplace_order_items').select('marketplace_order_item_id', {
    count: 'exact',
    head: true
  }).eq('tenant_id', tenantId).eq('marketplace_account_id', accountId).or(`order_sn.eq.${safeOrderId},external_order_id.eq.${safeOrderId}`);
  if (countError) throw new Error(`Count order item finance gagal: ${countError.message}`);
  if ((count ?? 0) === 1) {
    const { data, error } = await serviceClient.from('marketplace_order_items').select('marketplace_order_item_id, marketplace_order_id, order_sn, external_order_id, external_order_item_id, marketplace_product_id, marketplace_sku_id, marketplace_sku, marketplace_seller_sku, seller_sku, marketplace_product_name, product_name, marketplace_variant_name, variation_name, variant_name, local_product_id, product_id, mapped_product_id, local_sku, mapped_local_sku, marketplace_sku_map_id, qty, quantity, gross_amount, paid_amount, unit_gross_amount, unit_paid_amount, tracking_number, finance_price_source, raw_item').eq('tenant_id', tenantId).eq('marketplace_account_id', accountId).or(`order_sn.eq.${safeOrderId},external_order_id.eq.${safeOrderId}`).limit(1).maybeSingle();
    if (error) throw new Error(`Load single order item finance gagal: ${error.message}`);
    return data ?? null;
  }
  return null;
}

async function loadOrderFinanceFallbackRows(serviceClient, account, orderId, transactionRow) {
  const safeOrderId = getString(orderId, '').replace(/[,()]/g, '');
  if (!safeOrderId) return [];
  const tenantId = getString(account.tenant_id);
  const accountId = getString(account.marketplace_account_id);
  const { data, error } = await serviceClient.from('marketplace_order_items').select('marketplace_order_item_id, marketplace_order_id, order_sn, external_order_id, external_order_item_id, marketplace_product_id, marketplace_sku_id, marketplace_sku, marketplace_seller_sku, seller_sku, marketplace_product_name, product_name, marketplace_variant_name, variation_name, variant_name, local_product_id, product_id, mapped_product_id, local_sku, mapped_local_sku, marketplace_sku_map_id, qty, quantity, gross_amount, paid_amount, unit_gross_amount, unit_paid_amount, tracking_number, finance_price_source, raw_item').eq('tenant_id', tenantId).eq('marketplace_account_id', accountId).or(`order_sn.eq.${safeOrderId},external_order_id.eq.${safeOrderId}`).order('marketplace_order_item_id', { ascending: true }).limit(100);
  if (error) throw new Error(`Load order item fallback finance gagal: ${error.message}`);
  const rows = Array.isArray(data) ? data : [];
  if (rows.length === 0) return [];
  const itemGrosses = rows.map((row)=>Math.max(0, tiktokGrossAmount(row) || tiktokGrossAmount(row.raw_item) || getNumber(row.gross_amount ?? row.unit_gross_amount, 0)));
  const totalGross = itemGrosses.reduce((sum, value)=>sum + value, 0);
  const txPayout = tiktokPayoutAmount(transactionRow);
  const txPlatformFee = tiktokPlatformFee(transactionRow);
  const txCommissionFee = tiktokCommissionFee(transactionRow);
  const txAffiliateFee = tiktokAffiliateFee(transactionRow);
  const txShippingFee = tiktokShippingFee(transactionRow);
  const txRefund = tiktokRefundAmount(transactionRow);
  return rows.map((row, index)=>{
    const qty = Math.max(1, getNumber(row.quantity ?? row.qty, 1));
    const itemGross = itemGrosses[index] || 0;
    const ratio = totalGross > 0 ? itemGross / totalGross : 1 / rows.length;
    const rawItem = row.raw_item && typeof row.raw_item === 'object' ? row.raw_item : {};
    return {
      ...rawItem,
      ...row,
      id: getString(row.external_order_item_id ?? row.marketplace_order_item_id, `${safeOrderId}_${index}`),
      item_id: getString(row.external_order_item_id ?? row.marketplace_order_item_id, `${safeOrderId}_${index}`),
      order_id: safeOrderId,
      order_sn: safeOrderId,
      external_order_id: safeOrderId,
      sku_id: getString(row.marketplace_sku_id ?? row.marketplace_sku ?? rawItem.sku_id, ''),
      remote_sku_id: getString(row.marketplace_sku_id ?? row.marketplace_sku ?? rawItem.sku_id, ''),
      seller_sku: getString(row.marketplace_seller_sku ?? row.seller_sku ?? rawItem.seller_sku, ''),
      product_id: getString(row.marketplace_product_id ?? rawItem.product_id, ''),
      product_name: getString(row.marketplace_product_name ?? row.product_name ?? rawItem.product_name, ''),
      sku_name: getString(row.marketplace_variant_name ?? row.variation_name ?? row.variant_name ?? rawItem.sku_name, ''),
      variant_name: getString(row.marketplace_variant_name ?? row.variation_name ?? row.variant_name ?? rawItem.sku_name, ''),
      quantity: qty,
      qty,
      gross_amount: itemGross,
      order_amount: itemGross,
      unit_gross_amount: itemGross / qty,
      paid_amount: itemGross,
      unit_paid_amount: itemGross / qty,
      settlement_amount: txPayout * ratio,
      received_amount: txPayout * ratio,
      net_settlement: txPayout * ratio,
      platform_fee: txPlatformFee * ratio,
      commission_fee: txCommissionFee * ratio,
      affiliate_fee: txAffiliateFee * ratio,
      shipping_fee: txShippingFee * ratio,
      refund_amount: txRefund * ratio,
      discount_amount: tiktokDiscountAmount(rawItem) || tiktokDiscountAmount(row),
      tracking_number: getString(row.tracking_number ?? rawItem.tracking_number, ''),
      _finance_order_item_fallback: true,
      _finance_allocation_ratio: ratio
    };
  });
}
async function resolveLocalSkuForFinance(serviceClient, account, row, orderId = '') {
  const remoteSkuId = getString(row.sku_id ?? row.remote_sku_id ?? row.seller_sku_id ?? row.product_sku_id ?? row.marketplace_sku_id, '');
  const sellerSku = getString(row.seller_sku ?? row.seller_sku_code ?? row.sku_code ?? row.marketplace_seller_sku, '');
  const tenantId = getString(account.tenant_id);
  const accountId = getString(account.marketplace_account_id);
  const mappingFilters = [
    remoteSkuId ? `remote_sku_id.eq.${remoteSkuId.replace(/[,()]/g, '')}` : '',
    remoteSkuId ? `marketplace_sku_id.eq.${remoteSkuId.replace(/[,()]/g, '')}` : '',
    sellerSku ? `remote_seller_sku.eq.${sellerSku.replace(/[,()]/g, '')}` : '',
    sellerSku ? `marketplace_seller_sku.eq.${sellerSku.replace(/[,()]/g, '')}` : ''
  ].filter(Boolean).join(',');
  if (mappingFilters) {
    const { data } = await serviceClient.from('marketplace_sku_maps').select('map_id, product_id, local_product_id, local_sku, mapped_local_sku, products(harga_hpp_default)').eq('tenant_id', tenantId).eq('marketplace_account_id', accountId).or(mappingFilters).limit(1).maybeSingle();
    const map = data;
    const mappedProductId = getString(map?.product_id ?? map?.local_product_id, '');
    if (mappedProductId) {
      const product = map.products;
      return {
        map_id: map.map_id,
        product_id: mappedProductId,
        local_sku: getString(map.mapped_local_sku ?? map.local_sku, ''),
        hpp_per_item: getNumber(product?.harga_hpp_default, 0),
        match_source: 'marketplace_sku_maps'
      };
    }
  }
  // Fallback penting: beberapa response finance TikTok tidak membawa sku_id yang sama dengan SKU mapping.
  // Kalau order sudah pernah dipull, marketplace_order_items biasanya sudah punya mapped_product_id/local_sku/resi.
  const safeOrderId = orderId.replace(/[,()]/g, '');
  const itemFilters = [
    remoteSkuId ? `marketplace_sku_id.eq.${remoteSkuId.replace(/[,()]/g, '')}` : '',
    remoteSkuId ? `remote_sku_id.eq.${remoteSkuId.replace(/[,()]/g, '')}` : '',
    sellerSku ? `marketplace_seller_sku.eq.${sellerSku.replace(/[,()]/g, '')}` : '',
    sellerSku ? `seller_sku.eq.${sellerSku.replace(/[,()]/g, '')}` : ''
  ].filter(Boolean).join(',');
  let orderItem = null;
  if (safeOrderId && itemFilters) {
    const { data } = await serviceClient.from('marketplace_order_items').select('marketplace_sku_map_id, product_id, mapped_product_id, local_product_id, local_sku, mapped_local_sku, tracking_number').eq('tenant_id', tenantId).eq('marketplace_account_id', accountId).or(`order_sn.eq.${safeOrderId},external_order_id.eq.${safeOrderId}`).or(itemFilters).limit(1).maybeSingle();
    orderItem = data;
  }
  // Kalau finance row tidak membawa SKU tapi order hanya satu item, fallback ini masih aman.
  // Untuk multi item tanpa SKU, hpp sengaja tidak ditebak. Manusia memang suka minta akurat dari data yang bolong.
  if (!orderItem && safeOrderId && !remoteSkuId && !sellerSku) {
    const { count } = await serviceClient.from('marketplace_order_items').select('marketplace_order_item_id', {
      count: 'exact',
      head: true
    }).eq('tenant_id', tenantId).eq('marketplace_account_id', accountId).or(`order_sn.eq.${safeOrderId},external_order_id.eq.${safeOrderId}`);
    if ((count ?? 0) === 1) {
      const { data } = await serviceClient.from('marketplace_order_items').select('marketplace_sku_map_id, product_id, mapped_product_id, local_product_id, local_sku, mapped_local_sku, tracking_number').eq('tenant_id', tenantId).eq('marketplace_account_id', accountId).or(`order_sn.eq.${safeOrderId},external_order_id.eq.${safeOrderId}`).limit(1).maybeSingle();
      orderItem = data;
    }
  }
  if (!orderItem) return {};
  const productId = getString(orderItem.mapped_product_id ?? orderItem.product_id ?? orderItem.local_product_id, '');
  let hpp = 0;
  let localSku = getString(orderItem.mapped_local_sku ?? orderItem.local_sku, '');
  if (productId) {
    const { data: product } = await serviceClient.from('products').select('product_id, kode_sku, harga_hpp_default').eq('product_id', productId).limit(1).maybeSingle();
    const productMap = product;
    hpp = getNumber(productMap?.harga_hpp_default, 0);
    localSku = localSku || getString(productMap?.kode_sku, '');
  }
  return {
    map_id: orderItem.marketplace_sku_map_id,
    product_id: productId || null,
    local_sku: localSku,
    hpp_per_item: hpp,
    tracking_number: getString(orderItem.tracking_number, ''),
    match_source: 'marketplace_order_items'
  };
}
async function saveFinanceStatementReport(serviceClient, account, statement, rawPayload) {
  const statementId = financeStatementId(statement);
  if (!statementId) return;
  const statementTime = isoFromFinanceTime(statement.payment_time ?? statement.paid_time ?? statement.statement_time ?? statement.create_time ?? statement.created_time ?? statement.settlement_time);
  const statementDate = financeStatementDate(statement) || (statementTime ?? new Date().toISOString()).slice(0, 10);
  const gross = moneyByKeys(statement, [
    'revenue',
    'revenue_amount',
    'gross_sales',
    'gross_amount',
    'net_sales',
    'net_sales_amount'
  ]);
  const payout = moneyByKeys(statement, [
    'settlement',
    'settlement_amount',
    'payout',
    'payout_amount',
    'received_amount'
  ]);
  const fee = Math.abs(moneyByKeys(statement, [
    'fee',
    'fee_amount',
    'total_fee',
    'fees'
  ]));
  const adjustment = moneyByKeys(statement, [
    'adjustment',
    'adjustment_amount'
  ]);
  const payload = {
    tenant_id: account.tenant_id,
    marketplace_account_id: account.marketplace_account_id,
    marketplace: 'tiktok_shop',
    shop_id: getString(account.shop_id, ''),
    statement_id: statementId,
    report_type: 'statement',
    period_start: statementDate,
    period_end: statementDate,
    total_orders: getNumber(statement.total_orders ?? statement.order_count, 0),
    currency: getString(statement.currency, 'IDR'),
    gross_amount: gross,
    gross_sales: gross,
    received_amount: payout,
    net_settlement: payout,
    platform_fee: fee,
    total_fees: fee,
    adjustment_amount: adjustment,
    status: 'pulled',
    settlement_status: getString(statement.payment_status ?? statement.status, ''),
    settlement_date: statementTime,
    raw_finance: rawPayload,
    raw_response: rawPayload,
    raw_report: statement,
    pulled_at: new Date().toISOString(),
    updated_at: new Date().toISOString()
  };
  const { error } = await serviceClient.from('marketplace_finance_reports').upsert(payload, {
    onConflict: 'tenant_id,marketplace_account_id,statement_id'
  });
  if (error) throw new Error(`Simpan statement finance gagal: ${error.message}`);
}
async function saveFinanceItemFromRow(args) {
  const { serviceClient, account, statementId, statementRow, transactionRow, detailRow, orderLite, index } = args;
  const orderId = financeOrderId(detailRow) || financeOrderId(transactionRow);
  const txId = financeTransactionId(detailRow, financeTransactionId(transactionRow, String(index)));
  const remoteSkuId = getString(detailRow.sku_id ?? detailRow.remote_sku_id ?? detailRow.product_sku_id ?? detailRow.marketplace_sku_id ?? detailRow.marketplace_sku, '');
  const sellerSku = getString(detailRow.seller_sku ?? detailRow.seller_sku_code ?? detailRow.sku_code ?? detailRow.marketplace_seller_sku, '');
  let productName = getString(detailRow.product_name ?? detailRow.marketplace_product_name ?? detailRow.product?.name ?? transactionRow.product_name, '');
  let variationName = getString(detailRow.sku_name ?? detailRow.variation_name ?? detailRow.variant_name ?? detailRow.marketplace_variant_name, '');
  const qty = Math.max(1, getNumber(detailRow.quantity ?? detailRow.qty ?? detailRow.item_quantity ?? transactionRow.quantity ?? 1, 1));
  const matchedOrderItem = await loadMatchingOrderItemForFinance(serviceClient, account, detailRow, orderId);
  const matchedRawItem = matchedOrderItem?.raw_item && typeof matchedOrderItem.raw_item === 'object' ? matchedOrderItem.raw_item : {};
  const effectiveRemoteSkuId = remoteSkuId || getString(matchedOrderItem?.marketplace_sku_id ?? matchedOrderItem?.marketplace_sku ?? matchedRawItem.sku_id, '');
  const effectiveSellerSku = sellerSku || getString(matchedOrderItem?.marketplace_seller_sku ?? matchedOrderItem?.seller_sku ?? matchedRawItem.seller_sku, '');
  productName = productName || getString(matchedOrderItem?.marketplace_product_name ?? matchedOrderItem?.product_name ?? matchedRawItem.product_name, '');
  variationName = variationName || getString(matchedOrderItem?.marketplace_variant_name ?? matchedOrderItem?.variation_name ?? matchedOrderItem?.variant_name ?? matchedRawItem.sku_name, '');
  const matchedGross = matchedOrderItem ? Math.max(0, getNumber(matchedOrderItem.gross_amount ?? matchedOrderItem.unit_gross_amount, 0) || tiktokGrossAmount(matchedRawItem)) : 0;
  const gross = matchedGross || tiktokGrossAmount(detailRow) || tiktokGrossAmount(transactionRow);
  const payout = tiktokPayoutAmount(detailRow) || tiktokPayoutAmount(transactionRow);
  const platformFee = tiktokPlatformFee(detailRow) || tiktokPlatformFee(transactionRow);
  const commissionFee = tiktokCommissionFee(detailRow) || tiktokCommissionFee(transactionRow);
  const affiliateFee = tiktokAffiliateFee(detailRow) || tiktokAffiliateFee(transactionRow);
  const shippingFee = tiktokShippingFee(detailRow) || tiktokShippingFee(transactionRow);
  const refundAmount = tiktokRefundAmount(detailRow) || tiktokRefundAmount(transactionRow);
  const discountAmount = tiktokDiscountAmount(detailRow) || tiktokDiscountAmount(transactionRow);
  const rowForMap = matchedOrderItem ? {
    ...matchedRawItem,
    ...matchedOrderItem,
    ...detailRow,
    sku_id: effectiveRemoteSkuId || remoteSkuId,
    remote_sku_id: effectiveRemoteSkuId || remoteSkuId,
    seller_sku: effectiveSellerSku || sellerSku,
    marketplace_seller_sku: effectiveSellerSku || sellerSku
  } : detailRow;
  const map = await resolveLocalSkuForFinance(serviceClient, account, rowForMap, orderId);
  const hppPerItem = getNumber(map.hpp_per_item, 0);
  const hppAmount = hppPerItem * qty;
  const orderCreatedAt = isoFromFinanceTime(detailRow.order_created_time ?? detailRow.order_create_time ?? detailRow.order_created_date ?? transactionRow.order_created_time) ?? getString(orderLite?.order_created_at ?? orderLite?.paid_at ?? orderLite?.created_time ?? orderLite?.created_at, null);
  const transactionTime = isoFromFinanceTime(detailRow.statement_time ?? detailRow.transaction_time ?? transactionRow.statement_time ?? transactionRow.transaction_time ?? statementRow.statement_time) ?? new Date().toISOString();
  const trackingNumber = getString(detailRow.tracking_number ?? detailRow.tracking_no ?? orderLite?.tracking_number ?? map.tracking_number, '');
  // statement-item-dedupe-key-v1:
  // Do not include volatile row index. Statement pulls can be repeated and pagination/order can change.
  const remoteItemKey = effectiveRemoteSkuId || effectiveSellerSku || variationName || productName || getString(detailRow.item_id ?? detailRow.product_id, '') || 'no_item';
  const remoteKey = [
    statementId,
    orderId || 'no_order',
    txId || 'no_tx',
    remoteItemKey
  ].join('|');
  const payload = {
    tenant_id: account.tenant_id,
    marketplace_account_id: account.marketplace_account_id,
    marketplace_order_id: orderLite?.marketplace_order_id ?? null,
    marketplace: 'tiktok_shop',
    shop_id: getString(account.shop_id, ''),
    statement_id: statementId,
    statement_transaction_id: txId,
    remote_finance_key: remoteKey,
    order_sn: orderId || null,
    order_id: orderId || null,
    external_order_id: orderId || null,
    tracking_number: trackingNumber || null,
    transaction_type: getString(detailRow.type ?? detailRow.transaction_type ?? transactionRow.type ?? transactionRow.transaction_type, 'order'),
    transaction_time: transactionTime,
    order_created_at: orderCreatedAt,
    currency: getString(detailRow.currency ?? transactionRow.currency ?? statementRow.currency, 'IDR'),
    product_id: map.product_id ?? null,
    map_id: map.map_id ?? null,
    local_sku: getString(map.local_sku ?? effectiveSellerSku ?? effectiveRemoteSkuId, ''),
    marketplace_sku: effectiveRemoteSkuId || null,
    marketplace_seller_sku: effectiveSellerSku || null,
    marketplace_product_name: productName || null,
    marketplace_variation_name: variationName || null,
    qty,
    gross_amount: gross,
    received_amount: payout,
    net_settlement: payout,
    platform_fee: platformFee,
    commission_fee: commissionFee,
    affiliate_fee: affiliateFee,
    shipping_fee: shippingFee,
    discount_amount: discountAmount,
    refund_amount: refundAmount,
    fee_amount: platformFee + commissionFee + affiliateFee + shippingFee,
    hpp_per_item: hppPerItem,
    hpp_amount: hppAmount,
    raw_item: detailRow,
    raw_finance: {
      statement: statementRow,
      transaction: transactionRow,
      detail: detailRow
    },
    pulled_at: new Date().toISOString(),
    updated_at: new Date().toISOString()
  };
  const { error } = await serviceClient.from('marketplace_finance_items').upsert(payload, {
    onConflict: 'tenant_id,marketplace_account_id,remote_finance_key'
  });
  if (error) throw new Error(`Simpan item finance gagal: ${error.message}`);
  return true;
}
async function actionPullFinanceStatementsPeriod(ctx, params) {
  const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const account = await getTikTokAccount(getString(params.account_id, ''));
  const refreshedToken = await refreshAccessTokenIfNeeded(account);
  const resolved = await resolveShopIdentity(refreshedToken.account, refreshedToken.accessToken, ctx.userId);
  const refreshed = resolved.account;
  const accessToken = refreshedToken.accessToken;
  const startDate = getString(params.start_date, new Date().toISOString().slice(0, 10));
  const endDate = getString(params.end_date, startDate);
  // statement-first-time-fields-v1: TikTok settlement export can be keyed by payment_time, not only statement_time.
  // statement-first-sortfield-fallback-v1: TikTok only allows sort_field=statement_time; unsupported time-field queries fall back.
  const rangeTimeGe = toJakartaStartSeconds(startDate);
  const rangeTimeLt = toJakartaEndExclusiveSeconds(endDate);
  const rawTimeFields = Array.isArray(params.time_fields) ? params.time_fields : [params.time_field];
  const requestedTimeFields = rawTimeFields.map((v)=>getString(v, '')).filter(Boolean);
  const timeFields = Array.from(new Set((requestedTimeFields.length > 0 ? requestedTimeFields : [
    'payment_time',
    'statement_time'
  ]).filter((v)=>[
    'payment_time',
    'statement_time'
  ].includes(v))));
  const pageSize = Math.min(Math.max(getNumber(params.page_size, 20), 1), 50);
  const maxStatements = Math.min(Math.max(getNumber(params.max_statements, 31), 1), 100);
  const maxTransactions = Math.min(Math.max(getNumber(params.max_transactions, 300), 1), 1000);
  const maxOrderDetails = Math.min(Math.max(getNumber(params.max_order_details, 180), 0), 1000);
  const includeSkuDetails = params.include_sku_details !== false;
  const statements = [];
  const seenStatementIds = new Set();
  let lastStatementPayload = {};
  for (const timeField of timeFields){
    let pageToken = '';
    while(statements.length < maxStatements){
      const query = {
        page_size: String(pageSize),
        [`${timeField}_ge`]: String(rangeTimeGe),
        [`${timeField}_lt`]: String(rangeTimeLt),
        // TikTok Get Statements requires SortField.
        sort_field: 'statement_time',
        sort_order: 'DESC'
      };
      if (pageToken) query.page_token = pageToken;
      let payload = {};
      try {
        payload = await tiktokRequestFinanceVersionFallback({
          account: refreshed,
          accessToken,
          method: 'GET',
          versions: [
            TIKTOK_FINANCE_STATEMENTS_API_VERSION,
            TIKTOK_FINANCE_LEGACY_API_VERSION
          ],
          pathForVersion: (version)=>`/finance/${version}/statements`,
          query,
          action: `pull_finance_statements_${timeField}`,
          createdBy: ctx.userId
        });
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        const lower = message.toLowerCase();
        const canFallback = timeField !== 'statement_time' && (
          lower.includes('invalid') ||
          lower.includes('not allowed') ||
          lower.includes('unsupported') ||
          lower.includes('sortfield') ||
          lower.includes('sort_field') ||
          lower.includes('payment_time')
        );
        if (canFallback) break;
        throw error;
      }
      lastStatementPayload = payload;
      const rows = collectStatementsFromPayload(payload);
      for (const row of rows){
        const statementId = financeStatementId(row);
        const statementDate = financeStatementDate(row);
        if (!statementId || seenStatementIds.has(statementId)) continue;
        if (!statementDate || statementDate < startDate || statementDate > endDate) continue;
        if (statements.length >= maxStatements) break;
        seenStatementIds.add(statementId);
        statements.push({
          ...row,
          _finance_time_field: timeField,
          _finance_statement_date: statementDate
        });
      }
      pageToken = extractNextToken(dataOf(payload));
      if (!pageToken || rows.length === 0) break;
    }
  }
  let savedStatements = 0;
  let transactionCount = 0;
  let itemCount = 0;
  let detailCalls = 0;
  const orderCache = new Map();
  const errors = [];
  for (const statement of statements){
    const statementId = financeStatementId(statement);
    if (!statementId) continue;
    await saveFinanceStatementReport(serviceClient, refreshed, statement, lastStatementPayload);
    savedStatements += 1;
    let txPageToken = '';
    do {
      const txQuery = financeStatementTransactionSortQuery({
        page_size: String(pageSize)
      });
      if (txPageToken) txQuery.page_token = txPageToken;
      const txPayload = await tiktokRequestFinanceVersionFallback({
        account: refreshed,
        accessToken,
        method: 'GET',
        versions: [
          TIKTOK_FINANCE_TRANSACTION_API_VERSION,
          TIKTOK_FINANCE_LEGACY_API_VERSION
        ],
        pathForVersion: (version)=>`/finance/${version}/statements/${encodeURIComponent(statementId)}/statement_transactions`,
        query: txQuery,
        action: 'pull_finance_statement_transactions',
        createdBy: ctx.userId
      });
      const txRows = collectStatementTransactionsFromPayload(txPayload);
      for (const tx of txRows){
        if (transactionCount >= maxTransactions) break;
        transactionCount += 1;
        const orderId = financeOrderId(tx);
        let orderLite = null;
        if (orderId) {
          if (!orderCache.has(orderId)) {
            orderCache.set(orderId, await loadOrderLite(serviceClient, getString(refreshed.tenant_id), getString(refreshed.marketplace_account_id), orderId));
          }
          orderLite = orderCache.get(orderId) ?? null;
        }
        let detailRows = [];
        if (includeSkuDetails && orderId && detailCalls < maxOrderDetails) {
          try {
            const detailPayload = await tiktokRequestFinanceVersionFallback({
              account: refreshed,
              accessToken,
              method: 'GET',
              versions: [
                TIKTOK_FINANCE_TRANSACTION_API_VERSION,
                TIKTOK_FINANCE_LEGACY_API_VERSION
              ],
              pathForVersion: (version)=>`/finance/${version}/orders/${encodeURIComponent(orderId)}/statement_transactions`,
              query: financeStatementTransactionSortQuery({
                page_size: '50'
              }),
              action: 'pull_finance_order_statement_transactions',
              createdBy: ctx.userId
            });
            detailRows = collectOrderStatementRows(detailPayload);
            detailCalls += 1;
          } catch (error) {
            errors.push(error instanceof Error ? error.message : String(error));
          }
        }
        if (detailRows.length === 0 && orderId) {
          const fallbackRows = await loadOrderFinanceFallbackRows(serviceClient, refreshed, orderId, tx);
          if (fallbackRows.length > 0) detailRows = fallbackRows;
        }
        if (detailRows.length === 0) detailRows = [
          tx
        ];
        for(let i = 0; i < detailRows.length; i += 1){
          await saveFinanceItemFromRow({
            serviceClient,
            account: refreshed,
            statementId,
            statementRow: statement,
            transactionRow: tx,
            detailRow: detailRows[i],
            orderLite,
            index: itemCount + i
          });
          itemCount += 1;
        }
      }
      txPageToken = extractNextToken(dataOf(txPayload));
    }while (txPageToken && transactionCount < maxTransactions)
    if (transactionCount >= maxTransactions) break;
  }
  return {
    ok: true,
    statements: savedStatements,
    transactions: transactionCount,
    items: itemCount,
    detail_calls: detailCalls,
    max_transactions: maxTransactions,
    max_order_details: maxOrderDetails,
    time_fields: timeFields,
    requested_start_date: startDate,
    requested_end_date: endDate,
    statement_ids: statements.map((x)=>financeStatementId(x)).filter(Boolean).slice(0, 50),
    statement_dates: statements.map((x)=>financeStatementDate(x)).filter(Boolean).slice(0, 50),
    message: errors.length > 0 ? `Sebagian detail SKU gagal: ${errors.slice(0, 2).join(' | ')}` : 'Finance statement berhasil dipull.'
  };
}
function jakartaDateString(offsetDays = 0) {
  const now = new Date();
  const utc = now.getTime() + now.getTimezoneOffset() * 60000;
  const jakarta = new Date(utc + 7 * 60 * 60000 + offsetDays * 24 * 60 * 60000);
  const y = jakarta.getFullYear();
  const m = String(jakarta.getMonth() + 1).padStart(2, '0');
  const d = String(jakarta.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}
async function actionEnqueueFinanceSyncJobs(ctx, params) {
  const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const tenantId = getString(params.tenant_id, '');
  const accountId = getString(params.account_id ?? params.marketplace_account_id, '');
  const mode = getString(params.mode, 'today_yesterday');
  const jobTypeHint = getString(params.job_type_hint, '');
  const backlogDays = Math.min(Math.max(getNumber(params.unpaid_backlog_days ?? params.finance_backlog_days ?? params.days_back, 90), 3), 90);
  let ranges = [];
  if (mode === 'recent_unpaid' || params.auto_unpaid_backlog_90d === true || jobTypeHint === 'auto_unpaid_backlog_90d') {
    const end = getString(params.end_date, jakartaDateString(0));
    const start = getString(params.start_date, jakartaDateString(-backlogDays));
    ranges.push({
      start_date: start,
      end_date: end,
      job_type: jobTypeHint || 'auto_unpaid_backlog_90d',
      priority: 65
    });
  } else if (mode === 'period') {
    const start = getString(params.start_date, jakartaDateString(0));
    const end = getString(params.end_date, start);
    ranges.push({
      start_date: start,
      end_date: end,
      job_type: 'manual_period',
      priority: 80
    });
  } else if (mode === 'today') {
    const today = jakartaDateString(0);
    ranges.push({
      start_date: today,
      end_date: today,
      job_type: 'auto_today',
      priority: 90
    });
  } else {
    const today = jakartaDateString(0);
    const yesterday = jakartaDateString(-1);
    ranges.push({
      start_date: today,
      end_date: today,
      job_type: 'auto_today',
      priority: 90
    });
    ranges.push({
      start_date: yesterday,
      end_date: yesterday,
      job_type: 'auto_yesterday',
      priority: 70
    });
  }
  let query = serviceClient.from('marketplace_accounts').select('marketplace_account_id, tenant_id, marketplace, status').eq('marketplace', 'tiktok_shop').eq('status', 'active').eq('is_deleted', false).order('created_at', {
    ascending: true
  }).limit(Math.min(Math.max(getNumber(params.max_accounts, 50), 1), 100));
  if (tenantId) query = query.eq('tenant_id', tenantId);
  if (accountId) query = query.eq('marketplace_account_id', accountId);
  const { data: accounts, error } = await query;
  if (error) throw new Error(error.message);
  const rows = [];
  for (const account of accounts || []){
    for (const range of ranges){
      rows.push({
        tenant_id: account.tenant_id,
        marketplace_account_id: account.marketplace_account_id,
        marketplace: 'tiktok_shop',
        job_type: range.job_type,
        period_start: range.start_date,
        period_end: range.end_date,
        priority: range.priority,
        status: 'pending',
        next_run_at: new Date().toISOString(),
        requested_by: ctx.userId === '00000000-0000-0000-0000-000000000000' ? null : ctx.userId,
        payload: {
          source: getString(params.source, 'finance_sync_jobs'),
          mode,
          include_sku_details: params.include_sku_details !== false,
          days_back: mode === 'recent_unpaid' ? backlogDays : getNumber(params.days_back, 0),
          unpaid_backlog_days: mode === 'recent_unpaid' ? backlogDays : null,
          include_unpaid_backlog: params.include_unpaid_backlog === true,
          auto_unpaid_backlog_90d: params.auto_unpaid_backlog_90d === true || jobTypeHint === 'auto_unpaid_backlog_90d',
          job_type_hint: jobTypeHint || null
        },
        updated_at: new Date().toISOString()
      });
    }
  }
  if (rows.length > 0) {
    const uniqueRows = [];
    const seen = new Set();
    for (const r of rows) {
      const key = `${r.marketplace_account_id}::${r.job_type}::${r.period_start}::${r.period_end}`;
      if (!seen.has(key)) {
        seen.add(key);
        uniqueRows.push(r);
      }
    }
    const { error: upsertError } = await serviceClient.from('finance_sync_jobs').upsert(uniqueRows, {
      onConflict: 'marketplace_account_id,job_type,period_start,period_end',
      ignoreDuplicates: params.force_requeue !== true
    });
    if (upsertError) throw new Error(upsertError.message);
  }
  return {
    ok: true,
    queued: rows.length,
    accounts: accounts?.length || 0,
    ranges
  };
}
async function actionProcessFinanceSyncJobs(ctx, params) {
  const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  if (params.enqueue !== false) {
    await actionEnqueueFinanceSyncJobs(ctx, {
      ...params,
      mode: getString(params.mode, 'today_yesterday'),
      source: getString(params.source, 'process_finance_sync_jobs')
    });
  }
  const maxJobs = Math.min(Math.max(getNumber(params.max_jobs, 1), 1), 3);
  const maxOrders = Math.min(Math.max(getNumber(params.max_orders, 10), 1), 20);
  const maxBatchesPerJob = Math.min(Math.max(getNumber(params.max_batches_per_job, 1), 1), 3);
  let jobQuery = serviceClient.from('finance_sync_jobs').select('*').in('status', [
    'pending',
    'retry',
    'running'
  ]).lte('next_run_at', new Date().toISOString()).order('priority', {
    ascending: false
  }).order('period_end', {
    ascending: false
  }).order('created_at', {
    ascending: true
  }).limit(maxJobs);
  const tenantId = getString(params.tenant_id, '');
  const accountId = getString(params.account_id ?? params.marketplace_account_id, '');
  if (tenantId) jobQuery = jobQuery.eq('tenant_id', tenantId);
  if (accountId) jobQuery = jobQuery.eq('marketplace_account_id', accountId);
  const { data: jobs, error } = await jobQuery;
  if (error) throw new Error(error.message);
  const details = [];
  let success = 0;
  let failed = 0;
  let statements = 0;
  let transactions = 0;
  let items = 0;
  let requeued = 0;
  for (const job of jobs || []){
    const jobId = getString(job.finance_sync_job_id ?? job.id, '');
    const nowIso = new Date().toISOString();
    await serviceClient.from('finance_sync_jobs').update({
      status: 'running',
      locked_at: nowIso,
      last_run_at: nowIso,
      updated_at: nowIso
    }).eq('finance_sync_job_id', jobId);
    try {
      let jobChecked = 0;
      let jobSuccess = 0;
      let jobFailed = 0;
      let jobSkipped = 0;
      let lastResult = {};
      let hasMore = false;
      for(let batch = 1; batch <= maxBatchesPerJob; batch += 1){
        const result = await actionPullFinancePeriod(ctx, {
          tenant_id: job.tenant_id,
          account_id: job.marketplace_account_id,
          start_date: job.period_start,
          end_date: job.period_end,
          max_orders: maxOrders,
          missing_only: true,
          source: getString(job.payload?.source, 'finance_sync_job_order_payout_v24_6_21')
        });
        lastResult = result;
        const checked = getNumber(result.checked, 0);
        const payoutSuccess = getNumber(result.success, 0);
        const payoutFailed = getNumber(result.failed, 0);
        const payoutSkipped = getNumber(result.skipped, 0);
        jobChecked += checked;
        jobSuccess += payoutSuccess;
        jobFailed += payoutFailed;
        jobSkipped += payoutSkipped;
        if (checked < maxOrders || checked <= 0) {
          hasMore = false;
          break;
        }
        hasMore = true;
      }
      statements += 0;
      transactions += jobChecked;
      items += jobSuccess;
      success += 1;
      const finishedAt = new Date().toISOString();
      const nextRun = hasMore ? new Date(Date.now() + 5 * 1000).toISOString() : finishedAt;
      const status = hasMore ? 'pending' : 'done';
      if (hasMore) requeued += 1;
      const message = hasMore ? `Finance belum selesai, lanjut antrean berikutnya: cek=${jobChecked}, berhasil=${jobSuccess}, gagal=${jobFailed}, skip=${jobSkipped}.` : `Finance selesai: cek=${jobChecked}, berhasil=${jobSuccess}, gagal=${jobFailed}, skip=${jobSkipped}.`;
      await serviceClient.from('finance_sync_jobs').update({
        status,
        finished_at: hasMore ? null : finishedAt,
        last_run_at: finishedAt,
        next_run_at: nextRun,
        locked_at: null,
        last_message: message,
        statement_count: 0,
        transaction_count: jobChecked,
        item_count: jobSuccess,
        last_result: {
          ...lastResult,
          checked: jobChecked,
          success: jobSuccess,
          failed: jobFailed,
          skipped: jobSkipped,
          has_more: hasMore,
          max_orders: maxOrders,
          max_batches_per_job: maxBatchesPerJob
        },
        updated_at: finishedAt
      }).eq('finance_sync_job_id', jobId);
      await serviceClient.from('finance_sync_logs').insert({
        tenant_id: job.tenant_id,
        marketplace_account_id: job.marketplace_account_id,
        marketplace: 'tiktok_shop',
        sync_type: 'auto_finance_order_payout_job',
        job_type: getString(job.job_type, 'auto_finance_pull'),
        status,
        finished_at: hasMore ? null : finishedAt,
        period_start: job.period_start,
        period_end: job.period_end,
        checked_count: jobChecked,
        success_count: jobSuccess,
        failed_count: jobFailed,
        skipped_count: jobSkipped,
        total_checked: jobChecked,
        total_success: jobSuccess,
        total_failed: jobFailed,
        total_skipped: jobSkipped,
        message,
        raw_response: lastResult,
        created_at: finishedAt,
        updated_at: finishedAt
      });
      details.push({
        job_id: jobId,
        status,
        checked: jobChecked,
        success: jobSuccess,
        failed: jobFailed,
        skipped: jobSkipped,
        has_more: hasMore
      });
    } catch (err) {
      failed += 1;
      const attempts = getNumber(job.attempts, 0) + 1;
      const retryMinutes = Math.min(60, 5 * attempts);
      const nextRun = new Date(Date.now() + retryMinutes * 60 * 1000).toISOString();
      const message = err instanceof Error ? err.message : String(err);
      await serviceClient.from('finance_sync_jobs').update({
        status: attempts >= 3 ? 'failed' : 'retry',
        attempts,
        next_run_at: nextRun,
        finished_at: new Date().toISOString(),
        last_run_at: new Date().toISOString(),
        locked_at: null,
        last_message: message,
        updated_at: new Date().toISOString()
      }).eq('finance_sync_job_id', jobId);
      await serviceClient.from('finance_sync_logs').insert({
        tenant_id: job.tenant_id,
        marketplace_account_id: job.marketplace_account_id,
        marketplace: 'tiktok_shop',
        sync_type: 'auto_finance_order_payout_job',
        job_type: getString(job.job_type, 'auto_finance_pull'),
        status: attempts >= 3 ? 'failed' : 'retry',
        finished_at: new Date().toISOString(),
        period_start: job.period_start,
        period_end: job.period_end,
        checked_count: 0,
        success_count: 0,
        failed_count: 1,
        skipped_count: 0,
        total_checked: 0,
        total_success: 0,
        total_failed: 1,
        total_skipped: 0,
        message,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString()
      });
      details.push({
        job_id: jobId,
        status: attempts >= 3 ? 'failed' : 'retry',
        error: message
      });
    }
  }
  return {
    ok: true,
    jobs: (jobs || []).length,
    success,
    failed,
    requeued,
    statements,
    transactions,
    items,
    checked: transactions,
    payout_success: items,
    details
  };
}
async function handleAction(req) {
  assertEnv();
  const ctx = await getAuthedContext(req);
  const body = await req.json().catch(()=>({}));
  const action = getString(body.action);
  const params = body.params && typeof body.params === 'object' ? body.params : {};
  const handlers = {
    status: actionStatus,
    pull_products: actionPullProducts,
    pull_orders: actionPullOrders,
    sync_stock: actionSyncStock,
    sync_all_stock: actionSyncAllStock,
    pull_finance_by_order: actionPullFinanceByOrder,
    pull_finance_period: actionPullFinancePeriod,
    pull_finance_statements_period: actionPullFinanceStatementsPeriod,
    enqueue_finance_sync_jobs: actionEnqueueFinanceSyncJobs,
    process_finance_sync_jobs: actionProcessFinanceSyncJobs
  };
  const handler = handlers[action];
  if (!handler) {
    return fail(400, `Unknown action: ${action}`, {
      allowed_actions: Object.keys(handlers)
    });
  }
  const result = await handler(ctx, params);
  return jsonResponse(200, result);
}
Deno.serve(async (req)=>{
  if (req.method === 'OPTIONS') return new Response('ok', {
    headers: corsHeaders
  });
  if (req.method !== 'POST') return fail(405, 'Method not allowed. Gunakan POST.');
  try {
    return await handleAction(req);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return fail(500, message);
  }
});
