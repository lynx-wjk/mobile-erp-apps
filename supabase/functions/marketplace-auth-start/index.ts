import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type",
  "access-control-allow-methods": "POST, OPTIONS",
};

type AuthAction = "connect_new" | "reconnect";
type ShopeeCredentials = {
  environment: "testing" | "production";
  host: string;
  partnerId: string;
  partnerKey: string;
  redirectUri: string;
  usedFallbackCredential: boolean;
  credentialSource: string;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  try {
    const supabaseUrl = requiredEnv("SUPABASE_URL");
    const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");

    const authHeader = req.headers.get("authorization") || "";
    const token = authHeader.replace(/^Bearer\s+/i, "").trim();
    if (!token) return json({ error: "UNAUTHORIZED_NO_AUTH_HEADER" }, 401);

    const admin = createClient(supabaseUrl, serviceRoleKey);
    const { data: authData, error: authError } = await admin.auth.getUser(token);
    if (authError || !authData.user) {
      return json({ error: "UNAUTHORIZED_INVALID_SESSION", message: authError?.message }, 401);
    }

    let body: any;
    try {
      body = await req.json();
    } catch (_) {
      return json({ error: "INVALID_JSON_BODY" }, 400);
    }

    const requestedMarketplace = clean(body?.marketplace);
    const action = normalizeAction(body?.auth_action || body?.action);
    const targetAccountId = clean(body?.marketplace_account_id || body?.target_marketplace_account_id);
    const requestedAlias = clean(body?.store_alias);
    const environment = normalizeEnvironment(body?.environment);

    const { data: profile, error: profileError } = await admin
      .from("users")
      .select("user_id, tenant_id, role_id, status")
      .eq("user_id", authData.user.id)
      .maybeSingle();

    if (profileError || !profile) return json({ error: "PROFILE_NOT_FOUND", message: profileError?.message }, 403);
    if (profile.status !== "active") return json({ error: "USER_NOT_ACTIVE" }, 403);

    const roleId = String(profile.role_id || "").toLowerCase();
    if (!["super_admin", "superadmin", "admin", "owner"].includes(roleId)) {
      return json({ error: "ROLE_NOT_ALLOWED" }, 403);
    }
    if (!profile.tenant_id) return json({ error: "USER_TENANT_ID_EMPTY" }, 400);

    let marketplace = requestedMarketplace;
    let storeAlias = requestedAlias;
    let finalEnvironment = environment;

    if (action === "reconnect") {
      if (!targetAccountId) return json({ error: "MARKETPLACE_ACCOUNT_ID_REQUIRED" }, 400);
      const { data: account, error: accountError } = await admin
        .from("marketplace_accounts")
        .select("marketplace_account_id, tenant_id, marketplace, store_alias, shop_name, status, environment")
        .eq("marketplace_account_id", targetAccountId)
        .eq("tenant_id", profile.tenant_id)
        .maybeSingle();

      if (accountError || !account) {
        return json({ error: "MARKETPLACE_ACCOUNT_NOT_FOUND", message: accountError?.message }, 404);
      }
      if (String(account.status || "").toLowerCase() === "deleted") {
        return json({ error: "MARKETPLACE_ACCOUNT_DELETED" }, 400);
      }

      marketplace = String(account.marketplace || "").trim();
      storeAlias = String(account.store_alias || account.shop_name || requestedAlias || "").trim();
      finalEnvironment = normalizeEnvironment(account.environment || finalEnvironment);
    }

    if (!["tiktok_shop", "shopee"].includes(marketplace)) {
      return json({ error: "INVALID_MARKETPLACE" }, 400);
    }
    if (!storeAlias) return json({ error: "STORE_ALIAS_REQUIRED" }, 400);

    const state = generateState();
    const expiresAt = new Date(Date.now() + 15 * 60 * 1000).toISOString();

    const { error: stateError } = await admin.from("marketplace_oauth_states").insert({
      state,
      tenant_id: profile.tenant_id,
      user_id: profile.user_id,
      marketplace,
      store_alias: storeAlias,
      status: "pending",
      expires_at: expiresAt,
      auth_action: action,
      target_marketplace_account_id: action === "reconnect" ? targetAccountId : null,
      environment: finalEnvironment,
    });

    if (stateError) return json({ error: "STATE_INSERT_FAILED", message: stateError.message }, 500);

    let shopeeCredential: ShopeeCredentials | null = null;
    const authorizationUrl = marketplace === "tiktok_shop"
      ? buildTikTokAuthUrl(state)
      : await buildShopeeAuthUrl(state, finalEnvironment, (credential) => shopeeCredential = credential);

    return json({
      ok: true,
      marketplace,
      state,
      store_alias: storeAlias,
      auth_action: action,
      marketplace_account_id: action === "reconnect" ? targetAccountId : null,
      environment: finalEnvironment,
      expires_at: expiresAt,
      authorization_url: authorizationUrl,
      shopee_host: shopeeCredential?.host,
      shopee_used_fallback_credential: shopeeCredential?.usedFallbackCredential ?? false,
      shopee_credential_source: shopeeCredential?.credentialSource,
      shopee_partner_id_masked: shopeeCredential ? maskPartnerId(shopeeCredential.partnerId) : null,
      shopee_redirect_uri_configured: Boolean(shopeeCredential?.redirectUri),
    });
  } catch (e) {
    return json({ error: "AUTH_START_FAILED", message: String(e) }, 500);
  }
});

function buildTikTokAuthUrl(state: string): string {
  const appKey = requiredEnv("TIKTOK_APP_KEY");
  const base = Deno.env.get("TIKTOK_AUTH_URL") || "https://services.tiktokshop.com/open/authorize";
  const serviceId = Deno.env.get("TIKTOK_SERVICE_ID") || "";
  const url = new URL(base);
  if (serviceId) url.searchParams.set("service_id", serviceId);
  else url.searchParams.set("app_key", appKey);
  url.searchParams.set("state", state);
  return url.toString();
}

async function buildShopeeAuthUrl(
  state: string,
  environment: string,
  onCredential?: (credential: ShopeeCredentials) => void,
): Promise<string> {
  const credential = resolveShopeeCredentials(environment);
  onCredential?.(credential);
  const path = "/api/v2/shop/auth_partner";
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const sign = await hmacSha256Hex(`${credential.partnerId}${path}${timestamp}`, credential.partnerKey);
  const redirect = new URL(credential.redirectUri);
  redirect.searchParams.set("state", state);
  const url = new URL(path, credential.host);
  url.searchParams.set("partner_id", credential.partnerId);
  url.searchParams.set("timestamp", timestamp);
  url.searchParams.set("sign", sign);
  url.searchParams.set("redirect", redirect.toString());
  return url.toString();
}

function resolveShopeeCredentials(environmentValue: unknown): ShopeeCredentials {
  const environment = normalizeEnvironment(environmentValue) as "testing" | "production";

  if (environment === "testing") {
    const testPartnerId = requiredEnv("SHOPEE_TEST_PARTNER_ID");
    const testPartnerKey = requiredEnv("SHOPEE_TEST_PARTNER_KEY");
    return {
      environment,
      host: optionalEnv("SHOPEE_TEST_HOST") || optionalEnv("SHOPEE_SANDBOX_HOST") || "https://openplatform.sandbox.test-stable.shopee.sg",
      partnerId: testPartnerId,
      partnerKey: testPartnerKey,
      redirectUri: optionalEnv("SHOPEE_TEST_REDIRECT_URI") || requiredEnv("SHOPEE_REDIRECT_URI"),
      usedFallbackCredential: false,
      credentialSource: "testing",
    };
  }

  return {
    environment,
    host: optionalEnv("SHOPEE_HOST") || "https://partner.shopeemobile.com",
    partnerId: requiredEnv("SHOPEE_PARTNER_ID"),
    partnerKey: requiredEnv("SHOPEE_PARTNER_KEY"),
    redirectUri: requiredEnv("SHOPEE_REDIRECT_URI"),
    usedFallbackCredential: false,
    credentialSource: "production",
  };
}

function maskPartnerId(value: string): string {
  const cleanValue = clean(value);
  if (!cleanValue) return "";
  if (cleanValue.length <= 4) return "***";
  return `${cleanValue.slice(0, 3)}...${cleanValue.slice(-2)}`;
}

function normalizeAction(value: unknown): AuthAction {
  const cleanValue = clean(value).toLowerCase();
  return cleanValue === "reconnect" ? "reconnect" : "connect_new";
}

function normalizeEnvironment(value: unknown): string {
  const cleanValue = clean(value).toLowerCase();
  if (["test", "testing", "dev", "development", "sandbox"].includes(cleanValue)) return "testing";
  return "production";
}

function clean(value: unknown): string {
  if (value === null || value === undefined) return "";
  return String(value).trim();
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

function generateState(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(24));
  const raw = Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${crypto.randomUUID()}_${raw}`;
}

async function hmacSha256Hex(message: string, secret: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(message));
  return Array.from(new Uint8Array(signature)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}
