import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.8";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface InsightsRequestBody {
  tenant_id?: string;
  model?: string;
  time_range_days?: number;
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    // Parse Body Parameters
    let body: InsightsRequestBody & { openrouter_api_key?: string } = {};
    try {
      body = await req.json();
    } catch {
      body = {};
    }

    const openRouterApiKey = (body.openrouter_api_key || Deno.env.get("OPENROUTER_API_KEY") || Deno.env.get("OPENAI_API_KEY") || "").trim();

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ ok: false, error: "Missing Authorization header" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const token = authHeader.replace("Bearer ", "").trim();
    const admin = createClient(supabaseUrl, serviceRoleKey);
    const anonClient = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY") || serviceRoleKey);

    // 1. Authenticate Requesting User
    const { data: { user }, error: authError } = await anonClient.auth.getUser(token);
    if (authError || !user) {
      return new Response(JSON.stringify({ ok: false, error: "Unauthorized: Invalid auth token" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // 2. Strict Role Authorization Check (super_admin only)
    const { data: userProfile, error: profileError } = await admin
      .from("users")
      .select("user_id, role_id, tenant_id, username")
      .eq("user_id", user.id)
      .maybeSingle();

    if (profileError || !userProfile) {
      return new Response(JSON.stringify({ ok: false, error: "User profile not found" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const roleClean = String(userProfile.role_id || "").toLowerCase().trim();
    const allowedRoles = ["super_admin", "superadmin", "owner", "platform_owner"];
    if (!allowedRoles.includes(roleClean)) {
      return new Response(JSON.stringify({ 
        ok: false, 
        error: "Forbidden: AI Smart Insights Engine is restricted to super_admin users only." 
      }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }


    // Strict Tenant Isolation: Only platform_owner can query arbitrary tenant_id. Super_admins are locked to their own tenant_id.
    const isPlatformOwner = roleClean === "platform_owner";
    let targetTenantId = userProfile.tenant_id;
    if (isPlatformOwner && body.tenant_id) {
      targetTenantId = body.tenant_id;
    } else if (body.tenant_id && body.tenant_id !== userProfile.tenant_id) {
      return new Response(JSON.stringify({ 
        ok: false, 
        error: "Forbidden: Cross-tenant data access denied. You can only view insights for your own store." 
      }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const selectedModel = body.model || "meta-llama/llama-3.3-70b-instruct";
    const days = Math.max(7, Math.min(body.time_range_days || 30, 90));
    const sinceIso = new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();

    // 3. Gather Financial & Inventory Telemetry
    const [ordersRes, financeRes, itemsRes, mapsRes] = await Promise.all([
      admin.from("marketplace_orders")
        .select("order_id, marketplace, order_status, total_amount, paid_amount, order_created_at")
        .eq("tenant_id", targetTenantId)
        .gte("order_created_at", sinceIso)
        .limit(2000),
      admin.from("marketplace_finance_reports")
        .select("finance_report_id, marketplace, net_settlement, payout_amount, pulled_at")
        .eq("tenant_id", targetTenantId)
        .gte("pulled_at", sinceIso)
        .limit(2000),
      admin.from("marketplace_order_items")
        .select("order_item_id, marketplace, mapping_status, quantity, item_price")
        .eq("tenant_id", targetTenantId)
        .limit(1000),
      admin.from("marketplace_sku_maps")
        .select("marketplace_sku_map_id, status, local_sku")
        .eq("tenant_id", targetTenantId)
        .eq("status", "active")
        .limit(1000)
    ]);

    const orders = ordersRes.data || [];
    const financeReports = financeRes.data || [];
    const orderItems = itemsRes.data || [];
    const skuMaps = mapsRes.data || [];

    // Aggregations
    const totalOrders = orders.length;
    const completedOrders = orders.filter(o => ["COMPLETED", "DELIVERED"].includes(String(o.order_status).toUpperCase())).length;
    const cancelledOrders = orders.filter(o => ["CANCELLED", "CANCELED"].includes(String(o.order_status).toUpperCase())).length;
    const inTransitOrders = orders.filter(o => ["IN_TRANSIT", "SHIPPED", "PROCESSED"].includes(String(o.order_status).toUpperCase())).length;

    const grossRevenue = orders.reduce((sum, o) => sum + (Number(o.total_amount) || Number(o.paid_amount) || 0), 0);
    const settledAmount = financeReports.reduce((sum, f) => sum + (Number(f.net_settlement) || Number(f.payout_amount) || 0), 0);

    const unmappedItemsCount = orderItems.filter(i => i.mapping_status === "unmapped").length;
    const totalActiveSkuMaps = skuMaps.length;

    const telemetry = {
      tenant_id: targetTenantId,
      time_range_days: days,
      metrics: {
        total_orders: totalOrders,
        completed_orders: completedOrders,
        in_transit_orders: inTransitOrders,
        cancelled_orders: cancelledOrders,
        gross_revenue_idr: grossRevenue,
        settled_payout_idr: settledAmount,
        unsettled_estimate_idr: Math.max(0, grossRevenue - settledAmount),
        unmapped_order_items: unmappedItemsCount,
        active_sku_mappings: totalActiveSkuMaps
      }
    };

    // 4. Fallback if OPENROUTER_API_KEY is not configured
    if (!openRouterApiKey) {
      return new Response(JSON.stringify({
        ok: true,
        source: "rule_engine_fallback",
        warning: "OPENROUTER_API_KEY environment variable is not configured. Returning rule-based AI insights fallback.",
        model: "rule_engine_v1",
        insights: {
          executive_summary: `Over the past ${days} days, the store processed ${totalOrders} orders generating Rp ${grossRevenue.toLocaleString('id-ID')} gross revenue with a settlement total of Rp ${settledAmount.toLocaleString('id-ID')}.`,
          financial_health: {
            status: settledAmount > 0 ? "Healthy" : "Attention Required",
            gross_revenue_idr: grossRevenue,
            settled_payout_idr: settledAmount,
            pending_payout_risk_idr: Math.max(0, grossRevenue - settledAmount),
            comment: `Total settled payout stands at ${Math.round((settledAmount / (grossRevenue || 1)) * 100)}% of gross revenue.`
          },
          inventory_insights: {
            unmapped_items_warning: unmappedItemsCount > 0 ? `${unmappedItemsCount} order items require local SKU mapping.` : "All order items are mapped.",
            active_mappings: totalActiveSkuMaps
          },
          actionable_recommendations: [
            unmappedItemsCount > 0 ? "Map unmapped marketplace SKUs to local SKUs to maintain stock accuracy." : "Maintain current SKU mappings.",
            "Monitor pending payout settlements for delivered orders.",
            "Review cancelled order trends to optimize product fulfillment."
          ]
        },
        telemetry
      }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // 5. Query OpenRouter API
    const systemPrompt = `You are the OpenRouter AI Smart Insights Engine for an Enterprise Marketplace ERP (TikTok Shop & Shopee). Analyze the store metrics provided and produce structured JSON containing executive_summary, financial_health, inventory_insights, and actionable_recommendations. Respond strictly in valid JSON format.`;
    const userPrompt = `Store Telemetry (${days} days): ${JSON.stringify(telemetry, null, 2)}`;

    const openRouterRes = await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${openRouterApiKey}`,
        "HTTP-Referer": "https://mdhproduction.com",
        "X-Title": "Mobile ERP AI Insights",
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        model: selectedModel,
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: userPrompt }
        ],
        response_format: { type: "json_object" },
        max_tokens: 1500,
        temperature: 0.3
      })
    });

    const openRouterJson = await openRouterRes.json().catch(() => null);
    if (!openRouterRes.ok || !openRouterJson) {
      throw new Error(`OpenRouter API error (HTTP ${openRouterRes.status}): ${JSON.stringify(openRouterJson)}`);
    }

    const aiContent = openRouterJson.choices?.[0]?.message?.content;
    let parsedInsights: any = null;
    try {
      parsedInsights = typeof aiContent === "string" ? JSON.parse(aiContent) : aiContent;
    } catch {
      parsedInsights = { raw_response: aiContent };
    }

    return new Response(JSON.stringify({
      ok: true,
      source: "openrouter_api",
      model: selectedModel,
      insights: parsedInsights,
      telemetry
    }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (err) {
    return new Response(JSON.stringify({
      ok: false,
      error: String(err instanceof Error ? err.message : err)
    }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
