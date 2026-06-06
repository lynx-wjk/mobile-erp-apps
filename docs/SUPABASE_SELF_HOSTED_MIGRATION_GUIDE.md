# Supabase Self-Hosted Migration Guide

Updated: 2026-05-28 WIB  
Target app: Stock Role Management App

This guide is for moving from Supabase Cloud project `tllknfqoczarogizheal` to a VPS-hosted Supabase stack. Treat the first run as a rehearsal on a disposable VPS before cutover.

## Official References

- Supabase Docker self-hosting: https://supabase.com/docs/guides/self-hosting/docker
- Restore Platform project to self-hosted: https://supabase.com/docs/guides/self-hosting/restore-from-platform
- Reverse proxy and HTTPS: https://supabase.com/docs/guides/self-hosting/self-hosted-proxy-https
- Backup/restore with CLI: https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore
- Database backups: https://supabase.com/docs/guides/platform/backups
- May 2026 self-host breaking change: https://supabase.com/changelog/46081-self-hosted-supabase-switching-studio-from-supabase-admin-to-postgres-breaking-c

## VPS Sizing

Minimum from Supabase Docker docs:

- RAM: 4 GB
- CPU: 2 cores
- Disk: 50 GB SSD

Recommended for this app:

- RAM: 8 GB+
- CPU: 4 cores+
- Disk: 80 GB+ SSD
- Daily off-server backup storage

If order/finance tables keep growing, separate database storage and backups become more important than raw CPU.

## Phase 1: Prepare A Test VPS

1. Point a test subdomain to the VPS, for example `supabase-test.yourdomain.com`.
2. Open ports `22`, `80`, and `443`. Keep database port closed publicly unless you intentionally use a private VPN.
3. Install packages:

```bash
sudo apt update
sudo apt install -y git curl ca-certificates openssl ufw
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
```

Log out and back in, then verify:

```bash
docker --version
docker compose version
```

## Phase 2: Install Supabase Docker

```bash
git clone --depth 1 https://github.com/supabase/supabase
mkdir supabase-project
cp -rf supabase/docker/* supabase-project/
cp supabase/docker/.env.example supabase-project/.env
cd supabase-project
```

Edit `.env`:

- Set strong `POSTGRES_PASSWORD`.
- Generate fresh `JWT_SECRET`, `ANON_KEY`, and `SERVICE_ROLE_KEY`.
- Set `SUPABASE_PUBLIC_URL=https://supabase-test.yourdomain.com`.
- Set `API_EXTERNAL_URL=https://supabase-test.yourdomain.com`.
- Set `SITE_URL=https://supabase-test.yourdomain.com`.
- Configure SMTP if login emails/password resets are used.
- Configure OAuth provider env vars if used.

Start services:

```bash
docker compose pull
docker compose up -d
docker compose ps
```

## Phase 3: Add HTTPS Reverse Proxy

Production self-hosted Supabase needs HTTPS. Use Caddy for the lightest path:

```bash
docker compose -f docker-compose.yml -f docker-compose.caddy.yml up -d
curl -I https://supabase-test.yourdomain.com/auth/v1/
```

Expected result is a reachable response, often `401` without auth headers. If it fails:

- Confirm DNS A record points to the VPS.
- Confirm ports `80` and `443` are open.
- Check `docker logs supabase-caddy`.

## Phase 4: Backup Cloud Project

From your local machine with Supabase CLI:

```bash
supabase db dump --db-url "CLOUD_CONNECTION_STRING" -f roles.sql --role-only
supabase db dump --db-url "CLOUD_CONNECTION_STRING" -f schema.sql
supabase db dump --db-url "CLOUD_CONNECTION_STRING" -f data.sql --use-copy --data-only
```

Free Plan note: Supabase recommends Free projects regularly export data using `supabase db dump` and keep off-site backups. Database backups do not include Storage objects, only metadata.

## Phase 5: Restore Database To Self-Hosted

Before restore, check extensions in Cloud:

```sql
select extname from pg_extension order by extname;
```

Enable matching extensions on self-hosted if needed.

Restore:

```bash
psql \
  --single-transaction \
  --variable ON_ERROR_STOP=1 \
  --file roles.sql \
  --file schema.sql \
  --command 'SET session_replication_role = replica' \
  --file data.sql \
  --dbname "postgres://postgres.your-tenant-id:POSTGRES_PASSWORD@supabase-test.yourdomain.com:5432/postgres"
```

If Cloud uses Postgres 17 and self-host starts with Postgres 15, rehearse this carefully. Common restore fixes include commenting out Postgres 17-only settings such as `SET transaction_timeout` and handling Auth/Storage schema version differences. Prefer starting self-hosted on Postgres 17 if your Cloud project is already on Postgres 17.

## Phase 6: Copy Storage Objects

Database restore keeps storage metadata, not object bytes. Copy storage separately:

1. In Cloud dashboard, enable/copy S3 access keys for Storage.
2. Copy buckets with an S3-compatible tool such as `rclone` or `aws s3 sync`.
3. Verify sample object URLs from the app after copy.

## Phase 7: Edge Functions And Scheduled Jobs

Copy or redeploy all Supabase Edge Functions used by the app:

- `marketplace-tiktok-service`
- `marketplace-order-sync-jobs`
- `marketplace-order-pull`
- `marketplace-return-refund-pull`
- `marketplace-stock-sync-worker`

Recreate secrets/environment variables:

- TikTok marketplace credentials
- Supabase URL and service role key for self-host
- Cron/job runner secrets
- SMTP and OAuth secrets

Recreate scheduled runners outside Supabase Cloud if needed. On a VPS, use one of:

- systemd timer
- cron
- GitHub Actions hitting HTTPS endpoints
- a small queue runner container in the same Docker network

## Phase 8: Apply App Baseline SQL

On self-hosted database, apply the current direct baseline:

```bash
psql "SELF_HOSTED_DB_URL" -v ON_ERROR_STOP=1 -f CLEAN_BASELINE_FINANCE_ORDER.sql
```

Do not apply cleanup first. Cleanup is only after finance/order smoke tests pass.

## Phase 9: Flutter Cutover

Update app environment:

- `SUPABASE_URL=https://supabase-test.yourdomain.com`
- publishable/anon key from self-host `.env`

Build a test APK and install only to internal test devices first:

```powershell
flutter clean
flutter pub get
flutter analyze --no-pub
flutter build apk --debug --no-pub
flutter run -d DEVICE_ID --no-pub --no-resident
```

## Phase 10: Smoke Test Checklist

Finance:

- Ringkasan: today, 7 days, current month, 30 days
- Marketplace tab
- SKU tab and SKU detail
- Arus Kas
- Biaya, including approved purchase source labels
- Laba Rugi
- Anomali, including negative payout aggregate
- Pull Finance
- Refresh Payout
- Finance auto job

Order/marketplace:

- Order marketplace list
- Auto Pull Order
- Order Job Monitor
- Non-completed order status refresh
- Stock out marketplace scan by resi/reference across dates
- Refund/cancel monitor detail
- SKU mapping search and HPP mapping

Backend checks:

- Negative payout raw total equals anomaly RPC aggregate.
- HPP missing count stays low/zero after cache refresh.
- No future-year/future-window order jobs.
- Pending/running order jobs stay small.
- Latest order date is current after pull.

## Phase 11: Cutover And Rollback

Cutover:

1. Freeze writes briefly if possible.
2. Take final `roles.sql`, `schema.sql`, and `data.sql`.
3. Restore to self-host.
4. Copy final Storage delta.
5. Apply baseline SQL.
6. Switch Flutter env to self-host URL/key.
7. Release internal build first.
8. Watch auth, order pull, finance pull, and logs.

Rollback:

- Keep the Cloud project untouched during the first cutover.
- Keep old Flutter env/build available.
- If smoke tests fail, switch app env/build back to Cloud, stop self-hosted scheduled jobs, and preserve self-host logs for analysis.

## May 2026 Self-Host Breaking Change Note

Supabase published a self-host breaking change on 2026-05-18: Studio and `postgres-meta` are moving from `supabase_admin` to `postgres` as the read/write role in self-hosted Docker defaults. Existing self-hosted instances that pull that change may need the official one-time ownership migration for objects created by Studio. New installs should still be tested, and old installs should not blindly pull `master` without reading the changelog.

## Do Not Forget

- Self-hosted Supabase is one project, not the full managed platform.
- You own OS updates, backups, monitoring, and disaster recovery.
- Storage bytes, Edge Functions, secrets, scheduled jobs, and OAuth callbacks need separate migration.
- Never expose `SERVICE_ROLE_KEY` in Flutter.
- Keep `CLEANUP_UNUSED_FUNCTIONS_AFTER_PASS.sql` unapplied until all smoke tests pass on the target database.
