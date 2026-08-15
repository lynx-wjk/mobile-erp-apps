# DevOps & Deployment Investigation Report

**Author**: Explorer 3 (DevOps & Deployment Specialist)  
**Date**: 2026-08-15T01:46:00+07:00  
**Target Host**: `inventory-vps` (`38.47.191.226`, Hostname: `lynx-wjk`)  
**Target Domain**: `https://mdhproduction.com`  

---

## 1. Observation

### A. VPS Host & Connectivity
- **SSH Connectivity**: Connection to host alias `inventory-vps` succeeds with user `root`, key `C:\Users\budic\.ssh\codex_vps_nopass_ed25519`.
- **Hostname**: `lynx-wjk`
- **Host OS & Resources**:
  - Memory: 3.8 GiB RAM total, 2.9 GiB used, ~1.0 GiB available. Swap: 8.0 GiB (7.0 GiB free).
  - Disk: `/dev/vda1` 69 GiB total, 30 GiB used, 36 GiB available (46% usage).
  - Web Server & SSL: Host Nginx 1.22.1 listening on ports 80, 443, 8088. SSL certificate at `/etc/nginx/ssl/mdhproduction.crt`.

### B. Docker Stack & Service Topology
The VPS runs 12 active Docker containers in a self-hosted Supabase + Web architecture:
| Container Name | Status | Port Bindings | Role / Path |
|---|---|---|---|
| `mobile-erp-web` | Up (Healthy) | `127.0.0.1:8089->80/tcp` | Nginx Alpine serving `/usr/share/nginx/html` mounted from `/root/mobile-erp-web/current` |
| `supabase-db` | Up 3 weeks (Healthy) | `5432/tcp` | PostgreSQL 15.8 database containing all schemas and RPC functions |
| `supabase-kong` | Up 3 weeks (Healthy) | `127.0.0.1:8050->8000/tcp`, `127.0.0.1:8443->8443/tcp` | API Gateway routing `/rest/v1/`, `/auth/v1/`, etc. |
| `supabase-rest` | Up 8 days (Healthy) | `3000/tcp` | PostgREST engine exposing PostgreSQL functions as REST endpoints |
| `supabase-auth` | Up 3 weeks (Healthy) | Internal | GoTrue Auth |
| `supabase-storage` | Up 3 weeks (Healthy) | `5000/tcp` | Storage API |
| `supabase-pooler` | Up 3 weeks (Healthy) | `127.0.0.1:5432->5432/tcp`, `127.0.0.1:6543->6543/tcp` | Supavisor connection pooler |
| `supabase-meta` | Up 3 weeks (Healthy) | `8080/tcp` | Metadata service |
| `supabase-studio` | Up 3 weeks (Healthy) | `3000/tcp` | Supabase Dashboard UI |
| `supabase-edge-functions` | Up (Healthy) | Internal | Deno edge functions runtime |
| `realtime-dev.supabase-realtime` | Up 3 weeks (Healthy) | Internal | WebSockets & Realtime engine |
| `supabase-imgproxy` | Up 3 weeks (Healthy) | `8080/tcp` | Image transformation service |

### C. Host Nginx Ingress Configuration (`/etc/nginx/sites-available/mdhproduction`)
- `https://mdhproduction.com/rest/v1/`, `/auth/v1/`, `/storage/v1/`, `/functions/v1/` are proxied to `http://127.0.0.1:8050` (`supabase-kong`).
- `https://mdhproduction.com/` and all static web assets are proxied to `http://127.0.0.1:8089` (`mobile-erp-web`).
- Critical entrypoints (`main.dart.js`, `flutter_bootstrap.js`, `flutter_service_worker.js`, `index.html`, `manifest.json`, `version.json`) have `Cache-Control: "no-cache, no-store, must-revalidate"`.

### D. Web Hosting Directory Structure on VPS
- Web root: `/root/mobile-erp-web/`
- Active Symlink: `/root/mobile-erp-web/current -> /root/mobile-erp-web/releases/rel_latest`
- Release target: `/root/mobile-erp-web/releases/rel_latest` contains the Flutter Web distribution bundle (`index.html`, `main.dart.js`, `assets/`, `canvaskit/`, `version.json`, etc.).
- Docker mount: `mobile-erp-web` binds `/root/mobile-erp-web/current` (read-only) to `/usr/share/nginx/html`.

### E. PostgreSQL Direct Execution Method
- Direct execution via root inside `supabase-db` does not prompt for password:
  ```powershell
  Get-Content <migration_file.sql> | ssh inventory-vps "docker exec -i supabase-db psql -U postgres -d postgres"
  ```
- Or inline query:
  ```powershell
  ssh inventory-vps "docker exec -i supabase-db psql -U postgres -d postgres -c 'SELECT <query>;'"
  ```

---

## 2. Logic Chain

1. **Database Migration Pipeline**:
   - The PostgreSQL instance runs inside the container `supabase-db`.
   - Any SQL file (e.g. `supabase/migrations/YYYYMMDDHHMMSS_fix_finance_retur_batal.sql`) can be executed synchronously from the local machine using PowerShell stdin piping over SSH into `docker exec -i supabase-db psql -U postgres -d postgres`.
   - PostgREST (`supabase-rest`) automatically refreshes its schema cache on DDL / function replacement, or can be refreshed via `NOTIFY pgrst, 'reload schema';` or `docker restart supabase-rest`.

2. **Web Build & Release Pipeline**:
   - Local Flutter environment is `Flutter 3.44.7 (Dart 3.12.2)`.
   - `lib/main.dart` contains default compile-time fallbacks for `SUPABASE_URL` (`https://mdhproduction.com`) and `SUPABASE_ANON_KEY`.
   - Running `flutter build web --release` produces the static bundle in `build/web`.
   - The contents of `build/web` can be packaged into a `.tar.gz` archive (`web_dist.tar.gz`), transferred to VPS (`/tmp/web_dist_fresh.tar.gz`), extracted directly into `/root/mobile-erp-web/releases/rel_latest`, and activated by restarting `mobile-erp-web` (`docker restart mobile-erp-web`).

3. **Safety & Zero Downtime**:
   - Disk space is 36 GiB available (46% used). A 16MB web bundle and SQL migration will take negligible space.
   - Nginx caching headers ensure browsers instantly fetch the new `main.dart.js` and `index.html` without stale asset caching issues.

---

## 3. Caveats

- **No Public Database Port**: PostgreSQL port 5432 is bound to `127.0.0.1` on the VPS. Direct access from external networks is prohibited for security; all DB interactions must happen via SSH command execution into `supabase-db` or SSH tunnel.
- **Service Restart Safety**: As per the `devops` skill rules, `docker compose down` must NOT be run. Individual container restarts (`docker restart mobile-erp-web`) are lightweight (~1 second) and safe.

---

## 4. Conclusion & Actionable Deployment Runbook

### Phase 1: Database Migration Execution Runbook
When applying the SQL migration file (e.g. `supabase/migrations/20260815020000_fix_retur_batal_and_unpaid_hpp.sql`):
```powershell
# 1. Execute SQL migration file on live PostgreSQL database
Get-Content supabase/migrations/20260815020000_fix_retur_batal_and_unpaid_hpp.sql | ssh inventory-vps "docker exec -i supabase-db psql -U postgres -d postgres"

# 2. Reload PostgREST schema cache
ssh inventory-vps "docker exec -i supabase-db psql -U postgres -d postgres -c 'NOTIFY pgrst, ''reload schema'';'"
```

### Phase 2: Web Build & Deployment Runbook
```powershell
# 1. Clean and build web release
flutter clean
flutter pub get
flutter build web --release

# 2. Compress the web build directory
tar -czf build/web_dist_fresh.tar.gz -C build/web .

# 3. SCP archive to VPS /tmp
scp build/web_dist_fresh.tar.gz inventory-vps:/tmp/web_dist_fresh.tar.gz

# 4. Extract on VPS and restart web container
ssh inventory-vps "mkdir -p /root/mobile-erp-web/releases/rel_latest && tar -xzf /tmp/web_dist_fresh.tar.gz -C /root/mobile-erp-web/releases/rel_latest/ && ln -sfn /root/mobile-erp-web/releases/rel_latest /root/mobile-erp-web/current && docker restart mobile-erp-web"
```

---

## 5. Verification Method

To independently verify database changes and web deployment:

1. **Verify Database Functions & Migration Output**:
   ```powershell
   ssh inventory-vps "docker exec -i supabase-db psql -U postgres -d postgres -c 'SELECT proname, prosrc FROM pg_proc WHERE proname IN (''finance_sku_order_line_details'', ''finance_sku_order_details_group_20260625'');'"
   ```

2. **Verify Live Web Application Status & Version**:
   ```powershell
   ssh inventory-vps "curl -I https://mdhproduction.com"
   ssh inventory-vps "curl -s https://mdhproduction.com/version.json"
   ```
   Expected: HTTP 200 OK with `Cache-Control: no-cache, no-store, must-revalidate` and valid `version.json` payload.
