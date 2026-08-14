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
- STRICT REAL API PAYOUT RULE: Never generate, force, or insert artificial/synthetic payout rows. Order payout status `has_payout` MUST strictly evaluate to `true` (`SETTLED`) ONLY IF an authentic API payout record exists in `marketplace_finance_reports` (`fmp.payout_total IS NOT NULL AND fmp.payout_total <> 0`). If an order lacks payout data, it MUST remain `has_payout = false` (`UNSETTLED / BELUM PAYOUT`) regardless of whether it is in a past month or current month.
- NEGATIVE PAYOUT RULE: Orders with negative payouts (`payout_amount < 0` due to return shipping fees or penalties) have finalized API escrow payloads, so `has_payout = true` (`SETTLED`). Their negative payout is added directly into `payout_total`, reducing total payout, and their COGS is included under `hpp_settled` so the net loss is accurately reflected.
- COGS SETTLEMENT RULE: `hpp_settled` (COGS Settled) ONLY includes COGS for orders with real API payouts (`fr.payout <> 0`). Orders without payout rows have their COGS classified under `unpaid_hpp` (`Est HPP Belum Payout`).
- AUTOMATED PAYOUT SYNC RULE: The background finance dispatcher and pull worker (`marketplace-finance-dispatcher` & `marketplace-finance-pull`) must invoke `public.sync_missing_completed_order_payouts()` to automatically detect completed orders missing payout records and upsert real escrow payout entries into `marketplace_finance_reports` mapped strictly by their original order creation date.

For marketplace:
- Order sync and finance sync must remain separate.
- Token refresh must work for TikTok and Shopee.
- Never hardcode single marketplace filters (e.g. `tiktok_shop`) in shared repository routines; ensure Shopee and TikTok Shop queries execute dynamically.
- Retention target is 90 days for order and finance data.
- Manual backfill must not break cron behavior.

For RPCs:
- Always ensure tables with RLS (`relrowsecurity = true`) have explicit `FOR SELECT` policies granted to `authenticated` and `anon` to avoid silent PostgREST `[]` responses.
- RPC string search parameters (`p_search`) must use tokenized search or fallback position matching to support multi-word product title lookups.
- Prefer canonical stable RPC names.
- Do not create version sprawl.
- Overwrite only when preserving the same canonical endpoint.

## MCP usage

Use:
- `supabase_selfhost` for schema, tables, migrations, and read-only database inspection.
- `vps_ssh` for Edge Function files, docker logs, cron inspection, and health checks.
- `github-mcp-server` for branches, PRs, and repository state.
