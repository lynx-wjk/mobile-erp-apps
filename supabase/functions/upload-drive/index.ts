import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const uploadUrl = Deno.env.get("GOOGLE_DRIVE_UPLOAD_URL") || "";
    const token = Deno.env.get("GOOGLE_DRIVE_UPLOAD_TOKEN") || "";

    if (!uploadUrl || !token) {
      return new Response(JSON.stringify({ error: "Upload configuration missing" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { fileName, mimeType, base64Data } = await req.json();

    const upstreamPayload = {
      token,
      fileName,
      mimeType,
      base64Data,
    };

    const upstreamResponse = await fetch(uploadUrl, {
      method: "POST",
      headers: {
        "Content-Type": "text/plain;charset=utf-8",
        "Accept": "application/json,text/plain,*/*",
      },
      body: JSON.stringify(upstreamPayload),
      redirect: "follow",
    });

    const text = await upstreamResponse.text();
    let decoded;
    try {
      decoded = JSON.parse(text);
    } catch (_) {
      decoded = null;
    }

    if (!upstreamResponse.ok) {
      return new Response(JSON.stringify({ error: "Apps Script upload failed", response: text }), {
        status: upstreamResponse.status,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify(decoded), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (err: any) {
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
