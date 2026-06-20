---
name: backend
description: Use this skill for Supabase backend work, database schema, RPCs, migrations, Edge Functions, marketplace sync logic, finance logic, auth, storage, and server-side data integrity.
---

# Backend Skill

Use this skill for backend work in the Stock Role Management App.

## Scope

Backend includes:
- Supabase Postgres schema
- SQL migrations
- RPC functions
- Edge Functions
- marketplace order/product/stock/finance sync
- cron jobs
- auth and role access
- storage policies
- finance calculation logic
- retention and cleanup jobs

## Required workflow

Before changing backend:
1. Inspect existing schema, RPCs, Edge Functions, and migrations.
2. Identify the stable source of truth.
3. Avoid duplicate RPC/function versions unless required.
4. Preserve currently stable behavior.
5. Explain affected tables/functions before applying changes.

## Safety rules

Default to read-only inspection.

Do not run destructive SQL unless explicitly approved:
- DROP
- TRUNCATE
- DELETE without precise WHERE
- UPDATE without precise WHERE
- destructive ALTER
- apply_migration that changes production behavior

Do not expose secrets:
- service_role key
- JWT secret
- database password
- marketplace secret
- full .env contents

## Project rules

For finance:
- Omzet only valid paid customer orders.
- Abnormal means payout minus or low margin below threshold.
- Use "Abnormal", not "Anomaly".
- Payout minus must stay in the order month.
- Default finance filter is current month until now.
- HPP mapping is the source of truth.
- Do not reintroduce default HPP fallback unless explicitly requested.

For marketplace:
- Order sync and finance sync must remain separate.
- Token refresh must work for TikTok and Shopee.
- Retention target is 90 days for order and finance data.
- Manual backfill must not break cron behavior.

For RPCs:
- Prefer canonical stable RPC names.
- Do not create version sprawl.
- Overwrite only when preserving the same canonical endpoint.

## MCP usage

Use:
- `supabase_selfhost` for schema, tables, migrations, and read-only database inspection.
- `vps_ssh` for Edge Function files, docker logs, cron inspection, and health checks.
- `github-mcp-server` for branches, PRs, and repository state.
