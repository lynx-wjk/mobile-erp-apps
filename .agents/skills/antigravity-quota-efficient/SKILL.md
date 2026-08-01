---
name: antigravity-quota-efficient
description: Use this skill for every Antigravity task when the user wants efficient work, low token usage, fewer tool calls, quota saving, minimal exploration, targeted inspection, compact reporting, and no unnecessary repeated analysis.
---

# Antigravity Quota Efficient Skill

Use this skill as an efficiency mode for Antigravity work.

## Main goal

Minimize quota usage while preserving correctness.

Work with:
- fewer tool calls
- narrower file reads
- bounded logs
- concise plans
- targeted edits
- no repeated analysis
- no unnecessary broad scanning
- no long explanations unless requested

## Required behavior

Before doing work:
1. Identify the exact objective.
2. Reuse known project context.
3. Avoid rediscovering stable facts.
4. Inspect only files, tables, logs, or commands needed for the task.
5. Prefer one focused plan over multiple exploratory loops.

When using tools:
- Batch related checks into one command when safe.
- Use grep/search before opening large files.
- Read only relevant file sections.
- Limit logs with --tail.
- Avoid full recursive scans unless necessary.
- Avoid running expensive checks repeatedly.
- Avoid screenshots unless UI/layout evidence is required.
- Avoid opening generated/build/cache folders.

## File inspection rules

Prefer targeted commands:
- git status --short
- git diff --stat
- git diff -- <file>
- grep/ripgrep for exact symbol names
- sed/Get-Content around relevant line ranges

Avoid:
- reading entire large files
- scanning node_modules/build/.dart_tool/android build outputs
- reading lock files unless dependency issue requires it
- opening unrelated modules

## Backend efficiency rules

For Supabase/backend:
- Inspect existing RPC/table/function first.
- Do not list all database objects unless needed.
- Use specific table/function names when known.
- Prefer read-only queries.
- Limit result rows.
- Avoid broad SELECT * on large tables.
- Avoid running migrations until patch is reviewed.

Use `supabase_selfhost` only when database state matters.

## Frontend efficiency rules

For Flutter/frontend:
- Locate exact widget first.
- Patch smallest affected widget.
- Avoid redesign.
- Run flutter analyze only after code changes or when required.
- Do not rebuild Android unless explicitly needed.
- Prefer targeted compile/analyze evidence.

## DevOps efficiency rules

For VPS/DevOps:
- Start with bounded health check only.
- Use docker ps and selected docker logs --tail=100.
- Do not run docker stats repeatedly.
- Do not restart containers unless required.
- Do not edit production config without precise patch and rollback.

Use `vps_ssh` only when server state matters.

## Marketplace API efficiency rules

For Shopee/TikTok:
- Identify marketplace and flow first.
- Inspect only the affected worker/function.
- Use one account and bounded page/date window for tests.
- Do not run broad backfill.
- Do not pull all orders/products unless requested.
- Do not push stock broadly without dry-run and approval.

## SaaS efficiency rules

For SaaS planning:
- Separate MVP from later-scale work.
- Give compact recommendation.
- Avoid overengineering.
- State only required database/backend/frontend/devops changes.
- Prefer staged rollout.

## Reporting format

Use compact output:
- What was checked
- What was found
- What changed, if anything
- What remains
- Exact next command if user must run one

Avoid:
- long background explanation
- repeated summaries
- generic advice
- unnecessary markdown tables
- speculative alternatives unless requested

## Stop conditions

Stop after the acceptance criteria are met.

Do not keep exploring after:
- issue is identified
- patch is ready
- test evidence is sufficient
- user asked for only inspection
- user asked not to modify anything

## Approval rules

Ask before:
- destructive SQL
- production migration
- broad data backfill
- stock push
- container restart
- config exposing private services
- deleting files
- large refactor
- expensive full build

## Default instruction

When combined with another skill, this skill controls efficiency.

Examples:
- backend + antigravity-quota-efficient
- frontend + antigravity-quota-efficient
- devops + antigravity-quota-efficient
- marketplace-api-integrations + antigravity-quota-efficient
- saas-builder + antigravity-quota-efficient
