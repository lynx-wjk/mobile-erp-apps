---
name: saas-builder
description: Use this skill for building, validating, scaling, pricing, packaging, and operating the Stock Role Management App as a SaaS product for multiple tenants, clients, stores, roles, subscriptions, billing, onboarding, monitoring, support, and production readiness.
---

# SaaS Builder Skill

Use this skill when working on SaaS product architecture, monetization, multi-tenant design, onboarding, subscription plans, operational readiness, customer rollout, and production scaling.

## Scope

This skill covers:
- SaaS product strategy
- multi-tenant architecture
- tenant isolation
- role-based access control
- subscription plans
- billing and invoices
- trial/demo mode
- onboarding flow
- client/store/account limits
- usage limits
- feature gating
- pricing tiers
- upgrade/downgrade rules
- customer support workflow
- data retention
- backup and restore
- production monitoring
- self-hosted Supabase readiness
- SLA and operational risk
- go-to-market packaging

## Product context

The product is a Stock Role Management / Mobile ERP SaaS for UMKM and omnichannel sellers.

Core modules may include:
- inventory stock in/out
- QR/barcode scanning
- warehouse role
- production role
- finance role
- HR attendance
- host live tracking
- content creator tracking
- marketplace integration
- Shopee and TikTok Shop sync
- SKU mapping
- HPP mapping
- finance dashboard
- abnormal finance monitoring
- purchase evidence upload
- operational expenses
- marketplace job monitor

## Required workflow

Before proposing SaaS changes:
1. Identify whether the change affects product, backend, frontend, DevOps, billing, or operations.
2. Check existing app constraints and stable behavior.
3. Separate MVP needs from enterprise/scale needs.
4. Avoid overengineering before real client usage.
5. Prefer staged rollout.
6. State what changes are required in database, backend, frontend, and operations.
7. State risks, cost impact, and rollback path.

## Multi-tenant rules

Tenant isolation is mandatory.

Every tenant-scoped table must have clear tenant ownership.

Avoid cross-tenant leakage in:
- queries
- RPCs
- storage files
- Edge Functions
- marketplace accounts
- finance reports
- user roles
- background jobs
- logs and monitoring output

Before changing tenant logic:
- inspect schema and RLS/policy behavior.
- verify tenant_id usage.
- verify role scope.
- verify marketplace_account_id belongs to the correct tenant.
- verify finance/order queries cannot leak other tenant data.

## Subscription and pricing rules

Subscription plans should define:
- max users
- max stores
- max marketplace accounts
- max orders/month or sync limits
- retention period
- finance features
- marketplace sync frequency
- support level
- export/report access
- demo/read-only access

Avoid hardcoding plan behavior in UI only. Backend must enforce limits.

For this app, recommended plan dimensions:
- number of users
- number of stores
- number of Shopee accounts
- number of TikTok accounts
- monthly order volume
- finance reporting access
- automation frequency
- support level

## Billing rules

Before implementing billing:
- define plan table.
- define tenant subscription table.
- define subscription status.
- define grace period.
- define trial behavior.
- define payment verification flow.
- define manual override for admin.
- define downgrade behavior.
- define data retention after expiry.

Do not block operational access abruptly without a grace period unless explicitly requested.

## Demo and trial rules

Demo tenants must be isolated from production tenants.

Demo mode rules:
- read-only by default.
- no destructive actions.
- no real marketplace stock push.
- no real finance mutation.
- auto logout can be enabled.
- demo data must not mix with real tenant data.

Trial mode rules:
- clear expiry.
- limited marketplace accounts.
- limited users.
- clear upgrade path.
- no hidden production-only dependency.

## SaaS architecture rules

Prefer simple, durable architecture first:
- Supabase Postgres as source of truth.
- Edge Functions for marketplace/API workers.
- pg_cron and pg_net only when safe and observable.
- bounded workers.
- idempotent sync jobs.
- clear monitoring tables.
- local app cache only when it does not corrupt source-of-truth behavior.

Avoid:
- unbounded backfills
- unlimited cron fanout
- cross-tenant background jobs without tenant guard
- storing secrets in frontend
- exposing service_role
- exposing internal MCP endpoints
- relying on UI-only permission checks

## Data retention and compliance rules

Default project retention target:
- marketplace order data: 90 days
- finance sync data: 90 days
- UI default finance filter: current month until now

Before changing retention:
- identify affected tables.
- check finance reporting impact.
- check backfill strategy.
- check customer expectations.
- check storage cost impact.

## Production readiness checklist

Before calling a feature SaaS-ready, verify:
- tenant isolation
- role access
- onboarding flow
- error states
- empty states
- subscription enforcement
- backup strategy
- log visibility
- support diagnostics
- upgrade path
- rollback path
- mobile Android behavior
- web behavior where relevant
- Supabase self-hosted deployment behavior

## Operational rules

For a 4GB RAM self-hosted VPS:
- avoid heavy background jobs.
- keep sync bounded.
- monitor memory before increasing cron frequency.
- avoid broad multi-tenant sync without queue/limit.
- prefer staged scaling.

Check:
- docker stats --no-stream
- free -h
- df -h
- active cron jobs
- queue/backlog state
- slow queries where relevant

## Product decision rules

When deciding a SaaS feature:
- classify as MVP, Growth, or Enterprise.
- estimate engineering risk.
- estimate operational cost.
- define acceptance criteria.
- define how to test with one tenant first.
- define rollback.

Avoid adding features that increase support burden without clear value.

## UI and UX rules

For SaaS UI:
- onboarding must be clear.
- limits must be visible before blocking action.
- expired subscription state must be understandable.
- admin/owner controls must be separated from staff roles.
- finance pages must not expose internal cron/debug details.
- marketplace connection status must be actionable.

## Security rules

Never expose:
- service_role key
- JWT secret
- database password
- GitHub token
- marketplace secrets
- access tokens
- refresh tokens
- SSH private keys
- full .env contents

For SaaS:
- secrets must stay server-side.
- marketplace credentials must be tenant/account scoped.
- audit logs should exist for sensitive admin actions.
- support/admin impersonation must be restricted and logged if implemented.

## MCP usage

Use:
- `github-mcp-server` for repo state, branches, PRs, issues, and implementation planning.
- `supabase_selfhost` for schema, migrations, tenant tables, subscription tables, and read-only inspection.
- `vps_ssh` for deployment, Docker health, cron, logs, and resource monitoring.

Default to read-only inspection before changes.

## Output expectations

When asked for SaaS planning, provide:
- recommended approach
- affected modules
- database changes
- backend changes
- frontend changes
- DevOps impact
- risk
- test plan
- rollout plan

When asked for implementation, make the smallest safe change and preserve stable behavior.
