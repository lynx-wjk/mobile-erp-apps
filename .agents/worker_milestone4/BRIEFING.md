# BRIEFING — 2026-08-15T03:10:45+07:00

## Mission
Build Flutter Web in release mode and deploy live to VPS (https://mdhproduction.com), then verify live availability.

## 🔒 My Identity
- Archetype: worker
- Roles: implementer, qa, specialist
- Working directory: c:\Users\budic\Downloads\android\inventory_control_apps\.agents\worker_milestone4
- Original parent: fb78be9d-90b3-463a-a9e0-e1d38add13ae
- Milestone: Milestone 4 (Flutter Web Release Build & Live VPS Deployment)

## 🔒 Key Constraints
- Follow strictly the minimal change and non-destructive deployment procedures.
- Do NOT run `docker compose down`.
- Clean web release build (`flutter build web --release`).
- Package and deploy archive to `inventory-vps:/tmp/web_dist_fresh.tar.gz`.
- Extract to `/root/mobile-erp-web/releases/rel_latest/` and link `/root/mobile-erp-web/current`.
- Restart container `mobile-erp-web`.
- Full live verification of https://mdhproduction.com, `version.json`, `main.dart.js`.
- No cheating, no dummy artifacts. Genuine verification evidence required.

## Current Parent
- Conversation ID: fb78be9d-90b3-463a-a9e0-e1d38add13ae
- Updated: 2026-08-15T03:10:45+07:00

## Task Summary
- **What to build**: Flutter Web release bundle.
- **Success criteria**: Zero compilation errors, web artifacts produced, deployed to VPS, `curl -I https://mdhproduction.com` returns 200 OK, `version.json` verified.
- **Interface contracts**: PROJECT.md & explorer_survey_vps/handoff.md.

## Loaded Skills
- **verification-before-completion**: Evidence before claims; run full commands and inspect outputs.
- **devops**: Safe VPS operations, container restarts, SSH remote execution.

## Change Tracker
- **Files modified**: None (built and deployed release artifacts).
- **Build status**: `flutter build web --release` passed with exit code 0.
- **Deployment status**: Deployed to VPS `inventory-vps`, container `mobile-erp-web` restarted, verified live.

## Quality Status
- **Build/test result**: Pass (0 errors, verified HTTP 200 on live endpoints).
- **Lint status**: Clean.
- **Handoff report**: `c:\Users\budic\Downloads\android\inventory_control_apps\.agents\worker_milestone4\handoff.md`.
