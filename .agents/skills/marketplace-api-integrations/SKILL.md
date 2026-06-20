---
name: marketplace-api-integrations
description: Use this skill for Shopee Open Platform and TikTok Shop API work, including OAuth, token refresh, signatures, orders, products, stock sync, finance/settlement, returns/refunds, webhooks, rate limits, sandbox/production separation, and marketplace data reconciliation.
---

# Marketplace API Integrations Skill

Use this skill for professional Shopee Open Platform and TikTok Shop API integration work in the Stock Role Management App.

## Scope

This skill covers:
- Shopee Open Platform API
- TikTok Shop API
- OAuth authorization and reauthorization
- access token and refresh token lifecycle
- API signature generation
- sandbox, testing, and production environment separation
- order sync
- product and variant pull
- stock push
- finance, settlement, and payout pull
- return, refund, and cancellation sync
- webhook validation
- API rate limits
- pagination, cursor, and time-window sync
- marketplace SKU to local SKU mapping
- marketplace account health monitoring
- sync audit logs and retry logic

## Required workflow

Before changing marketplace API logic:
1. Identify the affected marketplace: Shopee, TikTok, or both.
2. Identify the affected flow: auth, order, product, stock, finance, return/refund, webhook, or monitor.
3. Inspect current implementation before proposing changes.
4. Check whether the account uses sandbox/testing or production.
5. Preserve stable behavior unless the user explicitly asks for a change.
6. Use bounded test runs before touching production-scale sync.
7. Explain the API endpoint, payload, affected table, and rollback path.

## Source of truth rules

Always prefer:
- official Shopee Open Platform documentation for Shopee behavior.
- official TikTok Shop API documentation for TikTok behavior.
- live database state for current account/token/sync status.
- existing app canonical mapping tables for SKU/HPP/account linkage.

Do not infer API behavior from memory when it affects production. Verify current endpoint requirements, signing rules, token rules, or status semantics before patching.

## Security rules

Never expose:
- Shopee partner key
- Shopee partner ID if treated as private in config
- TikTok app secret
- TikTok client secret
- access token
- refresh token
- service_role key
- database password
- full `.env` contents
- raw Authorization headers
- full signed request URL with secrets

When showing diagnostics, redact sensitive fields.

## OAuth and token rules

For every marketplace API flow:
- Check token expiry before API call.
- Refresh token automatically when allowed.
- Persist refreshed token atomically.
- Mark account as needing reauth only when refresh is impossible or rejected.
- Do not mark account disconnected just because one API call times out.
- Keep token refresh shared across product, order, stock, finance, and refund workers.
- Separate testing/sandbox credentials from production credentials.

For Shopee:
- Confirm environment before calling API.
- Do not mix sandbox partner credentials with production account routes.
- Treat `invalid_partner_id`, auth errors, and refresh errors as environment/config/auth issues first, not data bugs.

For TikTok Shop:
- Validate shop/account authorization state.
- Treat expired/invalid token separately from API throttling or payload validation errors.

## Signature and request rules

Before changing signed request logic:
- Verify parameter order.
- Verify timestamp handling.
- Verify path included in signature.
- Verify body inclusion or exclusion according to endpoint rules.
- Verify environment base URL.
- Verify HTTP method.
- Verify content type.

Never log raw signatures together with secrets.

## Sync rules

All sync jobs must be:
- idempotent
- resumable
- bounded by page/window limits
- safe to retry
- safe against duplicate rows
- explicit about time zone
- explicit about cursor/window state
- observable through logs/monitoring

For order sync:
- Keep order sync separate from finance sync.
- Avoid gaps in time windows.
- Use overlap windows where needed.
- Deduplicate by marketplace account, marketplace, order ID, item ID, and variant/SKU where applicable.
- Preserve canonical order statuses.

For finance sync:
- Keep payout and settlement data tied to the correct order date/month.
- Do not move payout minus into the wrong month.
- Do not use finance sync to mutate order status unless explicitly designed.
- Preserve existing finance source-of-truth RPC behavior.

For product and stock sync:
- Product pull should update product and variant snapshots without destroying local mapping.
- Stock push must use mapped marketplace product/variant IDs.
- Stock push must be dry-run or bounded test first unless explicitly approved.
- Do not push stock to production accounts without user confirmation.

For return/refund sync:
- Pull cancellation, return, and refund cases separately when the marketplace API separates them.
- Link return/refund records back to original order/item when possible.
- Do not treat all refunded/cancelled orders as the same finance event without checking settlement data.

## Rate limit and retry rules

When API errors happen:
- Distinguish auth errors, rate limits, bad payloads, marketplace validation errors, network timeouts, and server errors.
- Use exponential backoff for retryable failures.
- Do not retry non-retryable payload/config errors indefinitely.
- Store error code, message, endpoint, account ID, worker name, and attempt count.
- Keep logs bounded and redact secrets.

## Database rules

Before changing database schema or RPCs:
- Inspect existing tables, columns, indexes, constraints, and migrations.
- Avoid duplicate RPC/function version sprawl.
- Preserve canonical stable RPC names unless the user asks otherwise.
- Avoid destructive migrations without explicit approval.

Important marketplace-related entities may include:
- marketplace accounts
- token/auth state
- product snapshots
- variant snapshots
- SKU mappings
- stock sync logs
- order sync state
- finance settlement rows
- return/refund rows
- job monitor tables

## Testing rules

Use staged validation:
1. Read-only inspect account and token state.
2. Test one account.
3. Test one endpoint.
4. Test one page or bounded date window.
5. Verify inserted/updated row counts.
6. Verify UI/API monitor reflects result.
7. Only then expand scope.

For production:
- Never run broad backfill without explicit account, date range, page limit, and rollback plan.
- Never push stock broadly without dry-run evidence.
- Never rotate credentials without user confirmation.

## MCP usage

Use:
- `vps_ssh` for Edge Function files, Docker logs, cron jobs, worker logs, and deployed runtime checks.
- `supabase_selfhost` for account/token tables, sync state, mappings, migrations, and read-only SQL inspection.
- `github-mcp-server` for repo branches, PRs, diffs, and source history.

Default to read-only inspection first.
