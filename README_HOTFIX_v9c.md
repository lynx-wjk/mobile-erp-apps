# Marketplace Bootstrap v9c Repo/Hotfix Notes

Ini paket buat mencegah perubahan live hilang.

## Isi

1. `supabase/migrations/20260610201000_marketplace_bootstrap_monitor_v9c.sql`
   - Production-safe monitor/audit layer.
   - Tidak hardcode tenant/account.
   - Tidak menyentuh Finance/HPP stable.
   - Menambah page-limit audit dan status v2 agar bootstrap TikTok tidak dianggap completed palsu.

2. `supabase/functions/marketplace-bootstrap-order-worker/index.ts`
   - Helper Edge Function temporary untuk proses bootstrap jobs dengan page_size/max_pages dari payload.
   - Tidak mengganti `marketplace-order-pull`.
   - Tidak menyentuh Finance/HPP.
   - Untuk production final, lebih baik logic ini digabung ke `marketplace-order-sync-jobs` existing supaya tidak ada Edge Function tambahan permanen.

3. `supabase/sql/temporary_live_tiktok_bootstrap_worker_cron.sql`
   - TEMPORARY LIVE HOTFIX ONLY.
   - Hardcode tenant/account internal:
     - tenant: `ae730499-550b-4907-bb18-bbc2629c64f4`
     - TikTok account: `e21c4302-79d7-4abd-9b99-9dc23cb240eb`
   - Jangan jadikan migration production real-client.
   - Dipakai untuk drain retry queue TikTok internal secara single-flight.

## Stop temporary cron setelah selesai

```sql
select cron.unschedule('marketplace-bootstrap-order-worker-every-1-min');
```

## Status check

```sql
select status, count(1) jobs, coalesce(sum(order_count),0)::bigint orders, coalesce(sum(item_count),0)::bigint items
from public.marketplace_order_pull_jobs
where marketplace='tiktok_shop'
  and job_type='bootstrap_90d_adaptive_v1'
group by status
order by status;
```

Selesai kalau:
- `retry = 0`
- `pending = 0`
- `running = 0`
- `failed = 0`
- page-limit risk = 0

## Warning

Jangan push `temporary_live_tiktok_bootstrap_worker_cron.sql` sebagai migration real-client.
Itu cuma buat live internal test. Real-client harus generic per tenant/account.
