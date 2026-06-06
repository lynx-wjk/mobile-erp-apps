import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

Deno.serve(async (req) => {
  try {
    const url = new URL(req.url);
    const params = Object.fromEntries(url.searchParams.entries());

    const code =
      url.searchParams.get("code") ||
      url.searchParams.get("auth_code") ||
      url.searchParams.get("authorization_code");

    const state = url.searchParams.get("state");
    const appKeyFromCallback = url.searchParams.get("app_key");
    const shopRegion = url.searchParams.get("shop_region") || "ID";
    const locale = url.searchParams.get("locale") || "-";

    if (!code) {
      return redirectToResult({
        status: "warning",
        title: "Callback Aktif",
        message: "Callback TikTok aktif, tapi authorization code belum ada. Ini normal kalau URL dibuka manual.",
        marketplace: "tiktok_shop",
        shopName: "-",
        shopRegion,
        locale,
      });
    }

    if (!state) {
      return redirectToResult({
        status: "error",
        title: "State OAuth Tidak Ada",
        message: "Authorize harus dimulai dari halaman Marketplace Accounts supaya toko masuk tenant yang benar.",
        marketplace: "tiktok_shop",
        shopName: "-",
        shopRegion,
        locale,
      });
    }

    const appKey = requiredEnv("TIKTOK_APP_KEY");
    const appSecret = requiredEnv("TIKTOK_APP_SECRET");
    const supabaseUrl = requiredEnv("SUPABASE_URL");
    const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");
    const encryptionKey = requiredEnv("MARKETPLACE_TOKEN_ENCRYPTION_KEY");

    if (encryptionKey.length < 32) {
      throw new Error("MARKETPLACE_TOKEN_ENCRYPTION_KEY minimal 32 karakter.");
    }

    if (appKeyFromCallback && appKeyFromCallback !== appKey) {
      return redirectToResult({
        status: "error",
        title: "App Key Tidak Cocok",
        message: "App key dari callback TikTok tidak sama dengan TIKTOK_APP_KEY di Supabase.",
        marketplace: "tiktok_shop",
        shopName: "-",
        shopRegion,
        locale,
      });
    }

    const admin = createClient(supabaseUrl, serviceRoleKey);
    const oauthState = await loadAndValidateState(admin, state, "tiktok_shop", params);

    if (!oauthState.ok) {
      return redirectToResult({
        status: "error",
        title: "OAuth State Tidak Valid",
        message: oauthState.message,
        marketplace: "tiktok_shop",
        shopName: "-",
        shopRegion,
        locale,
      });
    }

    const tokenUrl = new URL("https://auth.tiktok-shops.com/api/v2/token/get");
    tokenUrl.searchParams.set("app_key", appKey);
    tokenUrl.searchParams.set("app_secret", appSecret);
    tokenUrl.searchParams.set("auth_code", code);
    tokenUrl.searchParams.set("grant_type", "authorized_code");

    const tokenRes = await fetch(tokenUrl.toString(), {
      method: "GET",
      headers: { accept: "application/json" },
    });

    const tokenJson = await tokenRes.json().catch(() => null);
    if (!tokenRes.ok || !tokenJson) {
      await failState(admin, state, `TikTok token exchange gagal. HTTP ${tokenRes.status}`);
      return redirectToResult({
        status: "error",
        title: "Token Exchange Gagal",
        message: `TikTok token exchange gagal. HTTP ${tokenRes.status}. Authorize ulang dari Marketplace Accounts.`,
        marketplace: "tiktok_shop",
        shopName: "-",
        shopRegion,
        locale,
      });
    }

    const tokenData = tokenJson.data ?? tokenJson;
    const accessToken = tokenData.access_token;
    const refreshToken = tokenData.refresh_token;

    if (!accessToken || !refreshToken) {
      await failState(admin, state, "TikTok tidak mengembalikan access_token / refresh_token.");
      return redirectToResult({
        status: "error",
        title: "Token Tidak Lengkap",
        message: "TikTok tidak mengembalikan access token atau refresh token.",
        marketplace: "tiktok_shop",
        shopName: "-",
        shopRegion,
        locale,
      });
    }

    const encryptedAccessToken = await encryptText(accessToken, encryptionKey);
    const encryptedRefreshToken = await encryptText(refreshToken, encryptionKey);
    const accessExpiredAt = expireValueToIso(tokenData.access_token_expire_in);
    const refreshExpiredAt = expireValueToIso(tokenData.refresh_token_expire_in);

    const shopInfo = await tryGetAuthorizedShops(appKey, appSecret, accessToken);
    const detectedShop = detectFirstShop(shopInfo);

    const shopId =
      shopIdValue(detectedShop) ||
      tokenData.open_id ||
      `${appKey}-${shopRegion}`;

    const shopCipher = shopCipherValue(detectedShop) || null;

    const shopName =
      shopNameValue(detectedShop) ||
      tokenData.seller_name ||
      oauthState.row.store_alias ||
      "TikTok Shop Authorized";

    await upsertMarketplaceAccount(admin, {
      tenant_id: oauthState.row.tenant_id,
      marketplace: "tiktok_shop",
      app_key: appKey,
      shop_region: shopRegion,
      shop_id: String(shopId),
      shop_cipher: shopCipher ? String(shopCipher) : null,
      shop_name: String(shopName),
      store_alias: oauthState.row.store_alias || String(shopName),
      access_token_encrypted: encryptedAccessToken,
      refresh_token_encrypted: encryptedRefreshToken,
      access_token_expired_at: accessExpiredAt,
      refresh_token_expired_at: refreshExpiredAt,
      raw_token_response: maskTokenObject(tokenJson),
      raw_shop_response: shopInfo ? maskTokenObject(shopInfo) : null,
      connected_by_user_id: oauthState.row.user_id,
      environment: normalizeEnvironment(oauthState.row.environment),
    }, oauthState.row);

    await admin
      .from("marketplace_oauth_states")
      .update({ status: "used", used_at: new Date().toISOString(), raw_callback_params: params, last_error: null })
      .eq("state", state);

    return redirectToResult({
      status: "success",
      title: "TikTok Shop Berhasil Terhubung",
      message: "Authorization berhasil. Token sudah dienkripsi dan disimpan ke tenant yang benar.",
      marketplace: "tiktok_shop",
      shopName: String(shopName),
      shopRegion,
      locale,
    });
  } catch (e) {
    return redirectToResult({
      status: "error",
      title: "Callback Error",
      message: String(e),
      marketplace: "tiktok_shop",
      shopName: "-",
      shopRegion: "ID",
      locale: "-",
    });
  }
});

async function loadAndValidateState(admin: any, state: string, marketplace: string, params: Record<string, string>) {
  const { data, error } = await admin
    .from("marketplace_oauth_states")
    .select("state, tenant_id, user_id, marketplace, store_alias, status, expires_at, auth_action, target_marketplace_account_id, environment")
    .eq("state", state)
    .maybeSingle();

  if (error || !data) return { ok: false, message: error?.message || "State tidak ditemukan." };
  if (data.marketplace !== marketplace) return { ok: false, message: "Marketplace state tidak cocok." };
  if (data.status !== "pending") return { ok: false, message: `State sudah ${data.status}. Generate link baru.` };
  if (new Date(data.expires_at).getTime() < Date.now()) {
    await admin.from("marketplace_oauth_states").update({ status: "expired", raw_callback_params: params }).eq("state", state);
    return { ok: false, message: "Authorization link expired. Generate link baru." };
  }
  return { ok: true, row: data };
}

async function failState(admin: any, state: string, message: string) {
  await admin.from("marketplace_oauth_states").update({ status: "failed", last_error: message }).eq("state", state);
}

async function upsertMarketplaceAccount(admin: any, payload: Record<string, any>, stateRow: Record<string, any>) {
  const now = new Date().toISOString();
  const authAction = normalizeAction(stateRow?.auth_action);
  const targetAccountId = cleanText(stateRow?.target_marketplace_account_id);

  const updateData = {
    ...payload,
    status: "active",
    is_deleted: false,
    deleted_at: null,
    deleted_by_user_id: null,
    last_error: null,
    updated_at: now,
    reauthorized_at: now,
  };

  if (authAction === "reconnect") {
    if (!targetAccountId) throw new Error("Reconnect state does not contain target marketplace account id.");

    const { data: target, error: targetError } = await admin
      .from("marketplace_accounts")
      .select("marketplace_account_id, tenant_id, marketplace, status")
      .eq("marketplace_account_id", targetAccountId)
      .eq("tenant_id", payload.tenant_id)
      .eq("marketplace", payload.marketplace)
      .maybeSingle();

    if (targetError || !target) {
      throw new Error(`Reconnect target marketplace account not found: ${targetError?.message || "not found"}`);
    }
    if (String(target.status || "").toLowerCase() === "deleted") {
      throw new Error("Reconnect target marketplace account has been deleted.");
    }

    const { error } = await admin
      .from("marketplace_accounts")
      .update(updateData)
      .eq("marketplace_account_id", targetAccountId);
    if (error) throw new Error(`Reconnect update marketplace account failed: ${error.message}`);
    return;
  }

  // Connect New Account must never update another shop only because app_key is the same.
  // Development shop and production shop commonly use the same app_key. Updating by app_key
  // is exactly how a real account gets overwritten by a test account. Charming disaster, avoided.
  let existing: any = null;
  if (cleanText(payload.shop_id)) {
    const { data, error } = await admin
      .from("marketplace_accounts")
      .select("marketplace_account_id")
      .eq("tenant_id", payload.tenant_id)
      .eq("marketplace", payload.marketplace)
      .eq("shop_id", payload.shop_id)
      .eq("shop_region", payload.shop_region)
      .or("is_deleted.is.false,is_deleted.is.null")
      .limit(1)
      .maybeSingle();

    if (error) throw new Error(`Find marketplace account by shop failed: ${error.message}`);
    existing = data;
  }

  if (existing?.marketplace_account_id) {
    const { error } = await admin
      .from("marketplace_accounts")
      .update(updateData)
      .eq("marketplace_account_id", existing.marketplace_account_id);
    if (error) throw new Error(`Update existing marketplace account failed: ${error.message}`);
    return;
  }

  const insertData = {
    ...updateData,
    stock_sync_enabled: false,
    connected_at: now,
    reauthorized_at: null,
    created_at: now,
  };

  const { error: insertError } = await admin
    .from("marketplace_accounts")
    .insert(insertData);

  if (!insertError) return;
  throw new Error(`Insert marketplace account failed: ${insertError.message}`);
}

function normalizeAction(value: unknown): string {
  const clean = cleanText(value).toLowerCase();
  return clean === "reconnect" ? "reconnect" : "connect_new";
}

function normalizeEnvironment(value: unknown): string {
  const clean = cleanText(value).toLowerCase();
  if (["test", "testing", "dev", "development", "sandbox"].includes(clean)) return "testing";
  return "production";
}

function cleanText(value: unknown): string {
  if (value === null || value === undefined) return "";
  const clean = String(value).trim();
  if (!clean || clean === "null" || clean === "undefined") return "";
  return clean;
}

async function tryGetAuthorizedShops(appKey: string, appSecret: string, accessToken: string) {
  try {
    const path = "/authorization/202309/shops";
    const timestamp = Math.floor(Date.now() / 1000).toString();
    const params: Record<string, string> = {
      app_key: appKey,
      timestamp,
    };
    params.sign = await signTikTokRequest(path, params, "", appSecret);

    const shopsUrl = new URL(`https://open-api.tiktokglobalshop.com${path}`);
    for (const [key, value] of Object.entries(params)) shopsUrl.searchParams.set(key, value);

    const res = await fetch(shopsUrl.toString(), {
      method: "GET",
      headers: {
        accept: "application/json",
        "x-tts-access-token": accessToken,
      },
    });

    const json = await res.json().catch(() => null);
    return { ok: res.ok, http_status: res.status, response: json };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

function detectFirstShop(shopInfo: any): any | null {
  const response = shopInfo?.response ?? shopInfo;
  const data = response?.data ?? response;
  const candidates = [
    data?.shops,
    data?.shop_list,
    data?.authorized_shops,
    data?.shops_list,
    data?.data?.shops,
    data?.data?.shop_list,
    response?.shops,
    response?.shop_list,
    response?.authorized_shops,
  ];

  for (const arr of candidates) {
    if (Array.isArray(arr) && arr.length > 0) return arr[0];
  }

  return null;
}

function shopCipherValue(shop: any): string | null {
  return text(shop?.shop_cipher)
    || text(shop?.cipher)
    || text(shop?.shopCipher)
    || text(shop?.shop?.shop_cipher)
    || text(shop?.seller?.shop_cipher);
}

function shopIdValue(shop: any): string | null {
  return text(shop?.shop_id)
    || text(shop?.id)
    || text(shop?.shop_code)
    || text(shop?.shopId)
    || text(shop?.shop?.id)
    || text(shop?.seller?.shop_id);
}

function shopNameValue(shop: any): string | null {
  return text(shop?.shop_name)
    || text(shop?.name)
    || text(shop?.shopName)
    || text(shop?.shop?.name)
    || text(shop?.seller?.shop_name);
}

function text(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  const clean = String(value).trim();
  if (!clean || clean === "null" || clean === "undefined") return null;
  return clean;
}

async function signTikTokRequest(path: string, params: Record<string, string>, bodyString: string, secret: string): Promise<string> {
  const sortedKeys = Object.keys(params)
    .filter((key) => key !== "sign" && key !== "access_token")
    .sort();

  let base = path;
  for (const key of sortedKeys) base += `${key}${params[key]}`;
  if (bodyString) base += bodyString;

  const signString = `${secret}${base}${secret}`;
  const encoder = new TextEncoder();
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", cryptoKey, encoder.encode(signString));
  return [...new Uint8Array(signature)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function expireValueToIso(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return null;
  const seconds = n > 1000000000 ? n : Math.floor(Date.now() / 1000) + n;
  return new Date(seconds * 1000).toISOString();
}

async function encryptText(plainText: string, secret: string): Promise<string> {
  const encoder = new TextEncoder();
  const keyHash = await crypto.subtle.digest("SHA-256", encoder.encode(secret));
  const key = await crypto.subtle.importKey("raw", keyHash, { name: "AES-GCM" }, false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, encoder.encode(plainText));
  return `aesgcm:${toBase64(iv)}:${toBase64(new Uint8Array(encrypted))}`;
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function maskToken(token: string | null | undefined): string | null {
  if (!token) return null;
  if (token.length <= 12) return "***";
  return `${token.slice(0, 6)}...${token.slice(-6)}`;
}

function maskTokenObject(input: any): any {
  if (input === null || input === undefined) return input;
  if (typeof input === "string") return input.length > 24 ? maskToken(input) : input;
  if (Array.isArray(input)) return input.map(maskTokenObject);
  if (typeof input === "object") {
    const out: Record<string, any> = {};
    for (const [key, value] of Object.entries(input)) {
      const lowerKey = key.toLowerCase();
      if (lowerKey.includes("token") || lowerKey.includes("secret") || lowerKey.includes("auth_code") || lowerKey === "code") {
        out[key] = typeof value === "string" ? maskToken(value) : "***";
      } else {
        out[key] = maskTokenObject(value);
      }
    }
    return out;
  }
  return input;
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value || !value.trim()) throw new Error(`Missing env: ${name}`);
  return value.trim();
}

function redirectToResult(args: {
  status: "success" | "warning" | "error";
  title: string;
  message: string;
  marketplace: string;
  shopName: string;
  shopRegion: string;
  locale: string;
}): Response {
  const configuredUrl = Deno.env.get("MARKETPLACE_CONNECT_RESULT_URL");
  if (!configuredUrl) {
    return new Response(`${args.title}\n\n${args.message}\n\nMarketplace: ${args.marketplace}\nShop: ${args.shopName}\nRegion: ${args.shopRegion}`, {
      status: args.status === "error" ? 400 : 200,
      headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" },
    });
  }

  const resultUrl = new URL(configuredUrl);
  resultUrl.searchParams.set("status", args.status);
  resultUrl.searchParams.set("title", args.title);
  resultUrl.searchParams.set("message", args.message);
  resultUrl.searchParams.set("marketplace", args.marketplace);
  resultUrl.searchParams.set("shop_name", args.shopName);
  resultUrl.searchParams.set("shop_region", args.shopRegion);
  resultUrl.searchParams.set("locale", args.locale);
  return Response.redirect(resultUrl.toString(), 302);
}
