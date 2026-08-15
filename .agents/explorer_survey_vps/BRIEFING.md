# BRIEFING — 2026-08-15T01:46:00+07:00

## Mission
Investigate VPS environment, build & deployment pipeline for mdhproduction.com, Docker Supabase containers, database migration execution methods, and web hosting paths.

## 🔒 My Identity
- Archetype: explorer
- Roles: DevOps & Deployment Specialist
- Working directory: c:\Users\budic\Downloads\android\inventory_control_apps\.agents\explorer_survey_vps
- Original parent: bf5a721a-983c-4c75-b5f8-b071203f463c
- Milestone: VPS & Deployment Survey

## 🔒 Key Constraints
- Read-only investigation — do NOT implement
- Verify VPS connectivity, docker status, web deploy paths, DB execution commands

## Current Parent
- Conversation ID: bf5a721a-983c-4c75-b5f8-b071203f463c
- Updated: 2026-08-15T01:46:00+07:00

## Investigation State
- **Explored paths**:
  - SSH alias `inventory-vps` (Host: 38.47.191.226, Hostname: `lynx-wjk`)
  - Docker containers (12 containers: `mobile-erp-web`, `supabase-db`, `supabase-kong`, etc.)
  - Host Nginx configuration: `/etc/nginx/sites-available/mdhproduction`
  - Web hosting directory: `/root/mobile-erp-web/` (releases in `/root/mobile-erp-web/releases/rel_latest`, symlink `/root/mobile-erp-web/current`)
  - Supabase stack directory: `/root/supabase-project/`
  - PostgreSQL direct execution method: `docker exec -i supabase-db psql -U postgres -d postgres`
  - Flutter Web build config & fallbacks (`lib/main.dart`, `web/index.html`, `Flutter 3.44.7`)
- **Key findings**:
  - Full deployment pipeline verified and documented. Direct SQL execution via stdin pipe into `supabase-db` works cleanly.
  - Web release deployment via tar archive extraction to `/root/mobile-erp-web/releases/rel_latest` and restarting `mobile-erp-web` container verified.
  - VPS health verified: 36GB disk available, ~1GB RAM available + 7GB free swap, all containers healthy.
- **Unexplored areas**: None for survey scope.

## Key Decisions Made
- Documented exact step-by-step SQL migration execution command and Flutter web build & deployment command pipeline.

## Artifact Index
- handoff.md — Final investigation handoff report
