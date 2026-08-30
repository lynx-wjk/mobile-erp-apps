import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

type ShopeeCredentials = {
  environment: "testing" | "production";
  host: string;
  partnerId: string;
  partnerKey: string;
  usedFallbackCredential: boolean;
  credentialSource: string;
};

Deno.serve(async (req) => {
  try {
    const url = new URL(req.url);
    const params = Object.fromEntries(url.searchParams.entries());
    const code = url.searchParams.get("code");
    const state = url.searchParams.get("state");
    const shopId = url.searchParams.get("shop_id") || url.searchParams.get("shopid");
    const mainAccountId = url.searchParams.get("main_account_id") || url.searchParams.get("merchant_id");
    const region = url.searchParams.get("region") || "ID";

    if (!code) {
      return redirectToResult({
        status: "warning",
        title: "Callback Aktif",
        message: "Callback Shopee aktif, tapi authorization code belum ada. Ini normal kalau URL dibuka manual.",
        marketplace: "shopee",
        shopName: "-",
        shopRegion: region,
      });
    }

    if (!state) {
      return redirectToResult({
        status: "error",
        title: "State OAuth Tidak Ada",
        message: "Authorize harus dimulai dari halaman Marketplace Accounts supaya toko masuk tenant yang benar.",
        marketplace: "shopee",
        shopName: "-",
        shopRegion: region,
      });
    }

    if (!shopId && !mainAccountId) {
      return redirectToResult({
        status: "error",
        title: "Shop ID Tidak Ada",
        message: "Shopee callback tidak mengirim shop_id atau main_account_id.",
        marketplace: "shopee",
        shopName: "-",
        shopRegion: region,
      });
    }

    const supabaseUrl = requiredEnv("SUPABASE_URL");
    const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");
    const encryptionKey = requiredEnv("MARKETPLACE_TOKEN_ENCRYPTION_KEY");

    if (encryptionKey.length < 32) {
      throw new Error("MARKETPLACE_TOKEN_ENCRYPTION_KEY minimal 32 karakter.");
    }

    const admin = createClient(supabaseUrl, serviceRoleKey);
    const oauthState = await loadAndValidateState(admin, state, "shopee", params);

    if (!oauthState.ok) {
      return redirectToResult({
        status: "error",
        title: "OAuth State Tidak Valid",
        message: oauthState.message,
        marketplace: "shopee",
        shopName: "-",
        shopRegion: region,
      });
    }

    const credential = resolveShopeeCredentials(oauthState.row.environment);
    const path = "/api/v2/auth/token/get";
    const timestamp = Math.floor(Date.now() / 1000).toString();
    const sign = await hmacSha256Hex(`${credential.partnerId}${path}${timestamp}`, credential.partnerKey);
    const tokenUrl = new URL(path, credential.host);
    tokenUrl.searchParams.set("partner_id", credential.partnerId);
    tokenUrl.searchParams.set("timestamp", timestamp);
    tokenUrl.searchParams.set("sign", sign);

    const body: Record<string, unknown> = {
      code,
      partner_id: Number(credential.partnerId),
    };

    if (shopId) body.shop_id = Number(shopId);
    if (mainAccountId) body.main_account_id = Number(mainAccountId);

    const tokenRes = await fetch(tokenUrl.toString(), {
      method: "POST",
      headers: {
        accept: "application/json",
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    });

    const tokenJson = await tokenRes.json().catch(() => null);
    if (!tokenRes.ok || !tokenJson) {
      await failState(admin, state, `Shopee ${credential.environment} token exchange gagal. HTTP ${tokenRes.status}`);
      return redirectToResult({
        status: "error",
        title: "Token Exchange Gagal",
        message: `Shopee ${credential.environment} token exchange gagal. HTTP ${tokenRes.status}. Authorize ulang dari Marketplace Accounts dengan Account Type yang sesuai.`,
        marketplace: "shopee",
        shopName: "-",
        shopRegion: region,
      });
    }

    if (tokenJson.error) {
      await failState(admin, state, `Shopee ${credential.environment} error: ${tokenJson.error} ${tokenJson.message || ""}`);
      return redirectToResult({
        status: "error",
        title: "Shopee Mengembalikan Error",
        message: `${tokenJson.error}: ${tokenJson.message || "Tidak ada detail."}`,
        marketplace: "shopee",
        shopName: "-",
        shopRegion: region,
      });
    }

    const accessToken = tokenJson.access_token;
    const refreshToken = tokenJson.refresh_token;

    if (!accessToken || !refreshToken) {
      await failState(admin, state, "Shopee tidak mengembalikan access_token / refresh_token.");
      return redirectToResult({
        status: "error",
        title: "Token Tidak Lengkap",
        message: "Shopee tidak mengembalikan access token atau refresh token.",
        marketplace: "shopee",
        shopName: "-",
        shopRegion: region,
      });
    }

    const finalShopId = String(tokenJson.shop_id || shopId || mainAccountId || "unknown");
    const shopName = oauthState.row.store_alias || `Shopee Shop ${finalShopId}`;

    const encryptedAccessToken = await encryptText(accessToken, encryptionKey);
    const encryptedRefreshToken = await encryptText(refreshToken, encryptionKey);
    const accessExpiredAt = expireValueToIso(tokenJson.expire_in);

    const accountId = await upsertMarketplaceAccount(admin, {
      tenant_id: oauthState.row.tenant_id,
      marketplace: "shopee",
      app_key: credential.partnerId,
      shop_region: region,
      shop_id: finalShopId,
      shop_cipher: null,
      shop_name: shopName,
      store_alias: oauthState.row.store_alias || shopName,
      access_token_encrypted: encryptedAccessToken,
      refresh_token_encrypted: encryptedRefreshToken,
      access_token_expired_at: accessExpiredAt,
      refresh_token_expired_at: null,
      raw_token_response: maskTokenObject({ ...tokenJson, environment: credential.environment, host: credential.host, credential_source: credential.credentialSource, used_fallback_credential: credential.usedFallbackCredential }),
      raw_shop_response: { callback_params: maskTokenObject(params) },
      connected_by_user_id: oauthState.row.user_id,
      environment: credential.environment,
    }, oauthState.row);

    await admin
      .from("marketplace_oauth_states")
      .update({ status: "used", used_at: new Date().toISOString(), raw_callback_params: params, last_error: null })
      .eq("state", state);

    if (accountId) {
      await triggerImmediateBootstrap({
        supabaseUrl,
        serviceRoleKey,
        tenantId: oauthState.row.tenant_id,
        marketplaceAccountId: accountId,
        marketplace: "shopee",
      });
    }

    return redirectToResult({
      status: "success",
      title: "Shopee Berhasil Terhubung",
      message: `Authorization berhasil untuk environment ${credential.environment}. Token sudah dienkripsi dan disimpan ke tenant yang benar.`,
      marketplace: "shopee",
      shopName,
      shopRegion: region,
    });
  } catch (e) {
    return redirectToResult({
      status: "error",
      title: "Callback Error",
      message: String(e),
      marketplace: "shopee",
      shopName: "-",
      shopRegion: "ID",
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
    return targetAccountId;
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
    return existing.marketplace_account_id;
  }

  const insertData = {
    ...updateData,
    stock_sync_enabled: false,
    connected_at: now,
    reauthorized_at: null,
    created_at: now,
  };

  const { data: inserted, error: insertError } = await admin
    .from("marketplace_accounts")
    .insert(insertData)
    .select("marketplace_account_id")
    .single();

  if (insertError || !inserted) throw new Error(`Insert marketplace account failed: ${insertError?.message}`);
  return inserted.marketplace_account_id;
}

async function triggerImmediateBootstrap(args: {
  supabaseUrl: string;
  serviceRoleKey: string;
  tenantId: string;
  marketplaceAccountId: string;
  marketplace: string;
}) {
  try {
    const cronSecret = Deno.env.get("MARKETPLACE_CRON_SECRET") || "4bb7142023541dee631ded0e18e7fddd7c45789cc6e89751154bc73cad21ffdd";
    const now = Math.floor(Date.now() / 1000);
    const startSeconds = now - (30 * 86400); // 30 days initial lookback

    const admin = createClient(args.supabaseUrl, args.serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    await admin.from("marketplace_order_sync_state").upsert(
      {
        tenant_id: args.tenantId,
        marketplace_account_id: args.marketplaceAccountId,
        marketplace: args.marketplace,
        bootstrap_status: "pending",
        bootstrap_from_seconds: startSeconds,
        bootstrap_to_seconds: now,
        bootstrap_cursor_seconds: startSeconds,
        recent_cursor_seconds: now,
        next_run_at: new Date().toISOString(),
        failure_count: 0,
        last_error: null,
        updated_at: new Date().toISOString(),
      },
      { onConflict: "tenant_id,marketplace_account_id,marketplace" }
    );

    fetch(`${args.supabaseUrl.replace(/\/+$/, "")}/functions/v1/marketplace-order-pull`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-marketplace-cron-secret": cronSecret,
      },
      body: JSON.stringify({
        tenant_id: args.tenantId,
        marketplace_account_id: args.marketplaceAccountId,
        marketplace: args.marketplace,
        mode: "bootstrap",
        start_seconds: startSeconds,
        end_seconds: now,
      }),
    }).catch((err) => console.warn(`[Immediate Pull Trigger Error] ${err}`));
  } catch (e) {
    console.warn(`[Immediate Pull Init Error] ${e}`);
  }
}

function resolveShopeeCredentials(environmentValue: unknown): ShopeeCredentials {
  const environment = normalizeEnvironment(environmentValue) as "testing" | "production";

  if (environment === "testing") {
    const testPartnerId = requiredEnv("SHOPEE_TEST_PARTNER_ID");
    const testPartnerKey = requiredEnv("SHOPEE_TEST_PARTNER_KEY");
    return {
      environment,
      host: optionalEnv("SHOPEE_TEST_HOST") || optionalEnv("SHOPEE_SANDBOX_HOST") || "https://partner.test-stable.shopeemobile.com",
      partnerId: testPartnerId,
      partnerKey: testPartnerKey,
      usedFallbackCredential: false,
      credentialSource: "testing",
    };
  }

  return {
    environment,
    host: optionalEnv("SHOPEE_HOST") || "https://partner.shopeemobile.com",
    partnerId: requiredEnv("SHOPEE_PARTNER_ID"),
    partnerKey: requiredEnv("SHOPEE_PARTNER_KEY"),
    usedFallbackCredential: false,
    credentialSource: "production",
  };
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

async function hmacSha256Hex(message: string, secret: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(message));
  return Array.from(new Uint8Array(signature)).map((b) => b.toString(16).padStart(2, "0")).join("");
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

function expireValueToIso(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return null;
  const seconds = Math.floor(Date.now() / 1000) + n;
  return new Date(seconds * 1000).toISOString();
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
      if (lowerKey.includes("token") || lowerKey.includes("secret") || lowerKey.includes("code") || lowerKey.includes("key")) {
        out[key] = typeof value === "string" ? maskToken(value) : "***";
      } else {
        out[key] = maskTokenObject(value);
      }
    }
    return out;
  }
  return input;
}

function optionalEnv(name: string): string | null {
  const value = Deno.env.get(name);
  if (!value || !value.trim()) return null;
  return value.trim();
}

function requiredEnv(name: string): string {
  const value = optionalEnv(name);
  if (!value) throw new Error(`Missing env: ${name}`);
  return value;
}

function redirectToResult(args: {
  status: "success" | "warning" | "error";
  title: string;
  message: string;
  marketplace: string;
  shopName: string;
  shopRegion: string;
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
  return Response.redirect(resultUrl.toString(), 302);
}
