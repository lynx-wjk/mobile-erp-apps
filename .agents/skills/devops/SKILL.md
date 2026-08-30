---
name: devops
description: Use this skill for VPS maintenance, Docker Supabase self-hosted operations, MCP access, SSH, tunnels, cron, backups, logs, deployment, monitoring, and safe production operations.
---

# DevOps Skill

Use this skill for VPS, Docker, Supabase self-hosted, deployment, monitoring, and operational maintenance.

## Scope

DevOps includes:
- VPS health
- Docker container status
- Supabase self-hosted stack
- Kong config
- SSH access
- MCP tunnel
- cron jobs
- logs
- backups
- environment configuration
- deployment checks
- resource monitoring

## Required workflow

Start with read-only checks:
- hostname
- docker ps --format '{{.Names}} {{.Status}}'

For logs, always use bounded output:
- docker logs --tail=100 <container>

Before changing production:
1. State the current condition.
2. State the exact command or file change.
3. State rollback path.
4. Ask for approval if the action can disrupt service.

## Safety rules

Do not run without explicit approval:
- docker compose down
- docker volume rm
- rm -rf
- reboot
- firewall changes
- deleting backups
- exposing internal ports publicly
- changing database credentials
- changing JWT/service keys
- modifying Kong routes that expose private services

Never expose:
- SSH private keys
- service_role key
- database password
- JWT secret
- GitHub token
- marketplace secrets
- full .env contents

## Supabase self-hosted rules

Supabase project path:
- /root/supabase-project

Kong config:
- /root/supabase-project/volumes/api/kong.yml

MCP endpoint must not be public. It should only be accessed through SSH tunnel.

Current local MCP tunnel pattern:
- ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:18080:KONG_CONTAINER_IP:8000 inventory-vps

If Kong restarts, container IP may change. Recheck with:
- ssh inventory-vps "docker inspect supabase-kong --format '{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}'"

Expected MCP GET check:
- HTTP/1.1 405 Method Not Allowed
- Allow: POST
- Server: kong/3.9.1

## Cron and jobs

Check cron safely before editing:
- pg_cron jobs
- marketplace order runner
- finance pull runner
- retention cleanup

Do not merge order sync and finance sync jobs.

## Resource monitoring

Check:
- free -h
- df -h
- docker stats --no-stream

Do not install heavy services on the 4GB RAM VPS without checking memory headroom.

## Flutter Web Nginx Gzip Deployment Rule

When deploying Flutter Web to Nginx servers configured with `gzip_static on;`:
1. Extract new web assets directly to the host release volume directory (e.g. `/root/mobile-erp-web/releases/rel_latest/`).
2. Remove stale `.gz` pre-compressed files (`rm -f main.dart.js.gz flutter_bootstrap.js.gz`).
3. Re-compress the updated bundles with gzip (`gzip -k -9 main.dart.js flutter_bootstrap.js`).
4. Ensure Nginx configuration serves `Cache-Control: no-cache, must-revalidate` for `main.dart.js`, `index.html`, and `flutter_bootstrap.js`.
5. Execute `docker exec mobile-erp-web nginx -s reload` (and reload host Nginx if reverse proxy caching is configured).

## MCP usage

Use:
- `vps_ssh` for VPS, Docker, logs, config, health, and tunnel diagnostics.
- `supabase_selfhost` for DB schema/migration inspection.
- `github-mcp-server` for repo, PRs, and deployment-related source changes.
