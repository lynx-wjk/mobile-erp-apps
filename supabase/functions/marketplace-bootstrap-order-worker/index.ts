import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
const VERSION = "marketplace-bootstrap-order-worker-v1-2026-06-10";
const CORS = {"access-control-allow-origin":"*","access-control-allow-headers":"authorization,apikey,content-type,x-marketplace-cron-secret,x-stock-sync-cron-secret","access-control-allow-methods":"POST,OPTIONS"};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return out({ ok:false, version:VERSION, message:"POST only" }, 405);
  try {
    const url = need("SUPABASE_URL").replace(/\/+$/, "");
    const key = need("SUPABASE_SERVICE_ROLE_KEY");
    const secret = String(Deno.env.get("MARKETPLACE_CRON_SECRET") || Deno.env.get("MARKETPLACE_AUTO_SYNC_CRON_SECRET") || Deno.env.get("STOCK_SYNC_CRON_SECRET") || "").trim();
    const incoming = String(req.headers.get("x-marketplace-cron-secret") || req.headers.get("x-stock-sync-cron-secret") || "").trim();
    if (!secret || incoming !== secret) return out({ ok:false, version:VERSION, message:"Invalid cron secret" }, 401);

    const body = await readJson(req);
    const tenant = txt(body.tenant_id);
    const account = txt(body.marketplace_account_id);
    const maxJobs = clamp(body.max_jobs, 1, 5, 2);
    const requeueRisk = body.requeue_page_limit_risk === true;
    const db = createClient(url, key, { auth:{ persistSession:false, autoRefreshToken:false } });

    if (requeueRisk) await requeue(db, tenant, account);

    const jobs = await claim(db, tenant, account, maxJobs);
    const result:any = { ok:true, version:VERSION, claimed:jobs.length, processed:0, failed:0, orders:0, items:0, details:[] };

    for (const job of jobs) {
      const p:any = job.payload && typeof job.payload === "object" ? job.payload : {};
      const pageSize = clamp(p.page_size ?? body.page_size ?? body.limit, 10, 50, 50);
      const maxPages = clamp(p.max_pages_per_window ?? body.max_pages, 1, 20, 5);
      const statuses = Array.isArray(p.target_statuses) ? p.target_statuses : undefined;

      const child:any = {
        tenant_id: job.tenant_id,
        marketplace_account_id: job.marketplace_account_id,
        source: "marketplace-bootstrap-order-worker",
        start_seconds: job.window_start_seconds,
        end_seconds: job.window_end_seconds,
        period_start: job.period_start,
        period_end: job.period_end,
        limit: pageSize,
        page_size: pageSize,
        max_pages: maxPages,
        max_details: clamp(p.max_details ?? body.max_details, 1, 5000, pageSize * maxPages),
        include_update_time_search: p.include_update_time_search === true,
        include_statusless_search: p.include_statusless_search !== false,
        skip_completed_order_pull: p.skip_completed_order_pull === true
      };
      if (statuses) child.statuses = statuses;

      const pulled = await callPull(url, key, secret, child);
      const data:any = pulled.data || {};
      const ok = pulled.status >= 200 && pulled.status < 300 && data.ok !== false;
      const orders = Number(data.orders || data.order_count || 0);
      const items = Number(data.items || data.item_count || 0);
      const warn = Number(data.warning_count || 0);

      await db.from("marketplace_order_pull_jobs").update({
        status: ok ? "done" : "failed",
        locked_at: null,
        finished_at: new Date().toISOString(),
        order_count: orders,
        item_count: items,
        warning_count: warn,
        last_message: ok
          ? `Bootstrap worker selesai: ${orders} order, ${items} item. max_pages=${maxPages}, page_size=${pageSize}.`
          : `Bootstrap worker gagal: ${String(data.message || pulled.status).slice(0,500)}`,
        last_result: data,
        updated_at: new Date().toISOString()
      }).eq("order_pull_job_id", job.order_pull_job_id);

      if (ok) { result.processed++; result.orders += orders; result.items += items; } else result.failed++;
      result.details.push({ job_id:job.order_pull_job_id, marketplace:job.marketplace, period_start:job.period_start, period_end:job.period_end, ok, orders, items, max_pages:maxPages, page_size:pageSize, http_status:pulled.status });
    }
    return out(result);
  } catch (e) {
    return out({ ok:false, version:VERSION, message:String(e instanceof Error ? e.message : e).slice(0,1000) }, 500);
  }
});

async function claim(db:any, tenant:string, account:string, maxJobs:number) {
  let q = db.from("marketplace_order_pull_jobs")
    .select("order_pull_job_id,tenant_id,marketplace_account_id,marketplace,period_start,period_end,window_start_seconds,window_end_seconds,payload,priority,next_run_at")
    .eq("job_type","bootstrap_90d_adaptive_v1")
    .eq("status","pending")
    .lte("next_run_at", new Date().toISOString())
    .order("priority",{ascending:false})
    .order("next_run_at",{ascending:true})
    .limit(maxJobs);
  if (tenant) q = q.eq("tenant_id", tenant);
  if (account) q = q.eq("marketplace_account_id", account);
  const { data, error } = await q;
  if (error) throw new Error(error.message);

  const rows:any[] = [];
  for (const r of data || []) {
    const { data:u, error:e } = await db.from("marketplace_order_pull_jobs").update({
      status:"running",
      locked_at:new Date().toISOString(),
      last_run_at:new Date().toISOString(),
      last_message:"Processing by marketplace-bootstrap-order-worker",
      updated_at:new Date().toISOString()
    })
      .eq("order_pull_job_id", r.order_pull_job_id)
      .eq("status","pending")
      .select("order_pull_job_id,tenant_id,marketplace_account_id,marketplace,period_start,period_end,window_start_seconds,window_end_seconds,payload,priority,next_run_at")
      .maybeSingle();
    if (e) throw new Error(e.message);
    if (u) rows.push(u);
  }
  return rows;
}

async function requeue(db:any, tenant:string, account:string) {
  let q = db.from("marketplace_bootstrap_page_limit_audit_v1")
    .select("order_pull_job_id")
    .eq("likely_page_limit_risk", true);
  if (tenant) q = q.eq("tenant_id", tenant);
  if (account) q = q.eq("marketplace_account_id", account);
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  const ids = (data || []).map((x:any)=>txt(x.order_pull_job_id)).filter(Boolean);
  if (!ids.length) return;
  const { error:e } = await db.from("marketplace_order_pull_jobs").update({
    status:"pending",
    locked_at:null,
    finished_at:null,
    next_run_at:new Date().toISOString(),
    last_message:"Requeued page-limit risk job for bootstrap worker",
    updated_at:new Date().toISOString()
  }).in("order_pull_job_id", ids);
  if (e) throw new Error(e.message);
}

async function callPull(url:string, key:string, secret:string, body:any) {
  const r = await fetch(`${url}/functions/v1/marketplace-order-pull`, {
    method:"POST",
    headers:{"content-type":"application/json","authorization":`Bearer ${key}`,"apikey":key,"x-marketplace-cron-secret":secret},
    body:JSON.stringify(body)
  });
  const t = await r.text();
  let data:any = {};
  try { data = t ? JSON.parse(t) : {}; } catch { data = { raw:t }; }
  return { status:r.status, data };
}

function out(x:any, status=200){return new Response(JSON.stringify(x),{status,headers:{...CORS,"content-type":"application/json"}})}
async function readJson(req:Request){try{return await req.json()}catch{return {}}}
function need(n:string){const v=Deno.env.get(n); if(!v) throw new Error(`${n} missing`); return v}
function txt(v:any){return v==null?"":String(v).trim()}
function clamp(v:any,min:number,max:number,fallback:number){const n=Number(v); return Number.isFinite(n)?Math.max(min,Math.min(max,Math.floor(n))):fallback}
