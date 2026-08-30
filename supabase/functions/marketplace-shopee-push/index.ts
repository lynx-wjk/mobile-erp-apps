import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type",
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

    // Official Shopee Push Codes:
    // Code 1: shop_authorization_push
    // Code 2: shop_authorization_canceled_push
    // Code 3: order_status_push
    // Code 4: order_trackingno_push
    // Code 8: reserved_stock_change_push
    // Code 15: shipping_document_status_push
    // Code 29: return_updates_push
    const code = Number(body?.code || body?.push_code || 0);
    const data = body?.data || body;
    const shopId = String(body?.shop_id || data?.shop_id || "");
    const orderSn = String(data?.ordersn || data?.order_sn || body?.ordersn || body?.order_sn || "").trim();

    console.log(`[Shopee Push Webhook] Code: ${code} Shop: ${shopId} Order: ${orderSn}`, JSON.stringify(data).slice(0, 200));

    if (code === 3 || code === 4 || code === 29 || code === 15) {
      // Find tenant for this shop_id
      if (shopId) {
        const { data: acc } = await admin
          .from("marketplace_accounts")
          .select("marketplace_account_id, tenant_id")
          .eq("marketplace", "shopee")
          .eq("shop_id", shopId)
          .eq("status", "active")
          .limit(1)
          .maybeSingle();

        if (acc) {
          const now = Math.floor(Date.now() / 1000);
          const startSeconds = now - (2 * 86400); // 2 days window for recent push

          // Trigger recent order pull asynchronously
          fetch(`${supabaseUrl.replace(/\/+$/, "")}/functions/v1/marketplace-order-pull`, {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "x-marketplace-cron-secret": cronSecret,
            },
            body: JSON.stringify({
              tenant_id: acc.tenant_id,
              marketplace_account_id: acc.marketplace_account_id,
              marketplace: "shopee",
              mode: "recent",
              start_seconds: startSeconds,
              end_seconds: now,
            }),
          }).catch((e) => console.warn(`[Shopee Push Pull Trigger Error] ${e}`));
        }
      }

      // Auto-sync payout records if RPC exists
      try {
        await admin.rpc("sync_missing_completed_order_payouts");
      } catch (_) {}
    } else if (code === 8) {
      console.log("[Shopee Stock Alert] Reserved stock changed:", data);
    } else if (code === 2) {
      console.warn("[Shopee Alert] Shop authorization canceled by seller! Shop:", shopId);
    }

    return new Response(JSON.stringify({ code: 0, message: "Shopee push event received successfully" }), {
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
