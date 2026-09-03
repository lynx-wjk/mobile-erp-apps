import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type, x-tts-signature",
  "access-control-allow-methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
    const cronSecret = Deno.env.get("MARKETPLACE_CRON_SECRET") || "4bb7142023541dee631ded0e18e7fddd7c45789cc6e89751154bc73cad21ffdd";
    const admin = createClient(supabaseUrl, serviceRoleKey);

    const rawBody = await req.text();
    let body: any = {};
    try {
      body = JSON.parse(rawBody);
    } catch (_) {
      body = {};
    }

    // Official TikTok Event Types from Console:
    // 1: Order Status Change, 2: Reverse Status Update, 3: Recipient Address Update, 
    // 4: Package Update, 5: Product Status Change, 6: Seller Deauthorization, 7: Auth Expire,
    // 11: Cancellation Request, 13: Settlement/Statement, 68: Inventory Change
    const type = Number(body?.type || body?.event_type || 0);
    const data = body?.data || body;
    const shopId = String(body?.shop_id || data?.shop_id || "");

    console.log(`[TikTok Shop Push Webhook] Type: ${type} Shop: ${shopId}`, JSON.stringify(data).slice(0, 200));

    // Type 1 (Order), 2 (Reverse/Return), 3 (Address), 4 (Package), 11 (Cancel Request)
    if (type === 1 || type === 2 || type === 3 || type === 4 || type === 11) {
      if (shopId) {
        const { data: acc } = await admin
          .from("marketplace_accounts")
          .select("marketplace_account_id, tenant_id")
          .eq("marketplace", "tiktok_shop")
          .eq("shop_id", shopId)
          .eq("status", "active")
          .limit(1)
          .maybeSingle();

        if (acc) {
          const now = Math.floor(Date.now() / 1000);
          const startSeconds = now - (2 * 86400);

          fetch(`${supabaseUrl.replace(/\/+$/, "")}/functions/v1/marketplace-order-pull`, {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "x-marketplace-cron-secret": cronSecret,
            },
            body: JSON.stringify({
              tenant_id: acc.tenant_id,
              marketplace_account_id: acc.marketplace_account_id,
              marketplace: "tiktok_shop",
              mode: "recent",
              start_seconds: startSeconds,
              end_seconds: now,
            }),
          }).catch((e) => console.warn(`[TikTok Push Pull Trigger Error] ${e}`));
        }
      }
    } else if (type === 13) {
      // Type 13: Settlement Statement Ready -> Trigger Finance Pull instantly
      if (shopId) {
        fetch(`${supabaseUrl.replace(/\/+$/, "")}/functions/v1/marketplace-finance-pull`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "x-marketplace-cron-secret": cronSecret,
          },
          body: JSON.stringify({ shop_id: shopId }),
        }).catch((e) => console.warn(`[TikTok Settlement Trigger Error] ${e}`));
      }
    } else if (type === 6) {
      console.warn("[TikTok Shop Alert] Seller deauthorized account! Shop:", shopId);
    } else if (type === 7) {
      console.warn("[TikTok Shop Alert] Authorization expiring soon! Shop:", shopId);
    }

    return new Response(JSON.stringify({ code: 0, message: "TikTok Shop push event received successfully" }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ code: 500, error: String(err) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
