---
name: frontend
description: Use this skill for Flutter UI, Android/Web behavior, layout fixes, role-based screens, finance UI, marketplace UI, upload flows, forms, navigation, and visual consistency.
---

# Frontend Skill

Use this skill for Flutter frontend work in the Stock Role Management App.

## Scope

Frontend includes:
- Flutter Android UI
- Flutter Web UI
- role-based page access
- forms and validation
- navigation
- finance dashboard UI
- marketplace monitor UI
- SKU mapping UI
- upload/photo UI
- responsive layout
- parsing and formatting display values

## Required workflow

Before changing frontend:
1. Locate the exact widget/page.
2. Preserve existing UI style unless the user asks for redesign.
3. Fix the smallest affected area.
4. Run static analysis after code changes.
5. Do not change backend contracts casually.

## Safety rules

Avoid:
- large UI rewrites
- unrelated refactors
- changing stable navigation
- changing role permissions without backend check
- changing financial formulas in UI if backend is source of truth

## Project rules

For finance UI:
- Use backend/RPC result as source of truth.
- Do not recalculate finance numbers in UI unless explicitly intended.
- Default filter is current month until now.
- Use "Abnormal", not "Anomaly".
- Avoid oversharing cron/internal diagnostic data in finance page.

For marketplace UI:
- Keep monitor job details concise.
- Pull order UI should support manual date range.
- Search should support order ID/resi/SKU where relevant.

For forms:
- Preserve Indonesian formatting.
- Price input must not break on dot/thousand separators.
- Currency and period fields must remain visible and usable on small screens.

For responsive layout:
- Check small Android screen behavior.
- Avoid overflow/red screen.
- Prefer scrollable, constrained layouts.

## MCP usage

Use:
- `github-mcp-server` for repo inspection and PR state.
- `vps_ssh` only if frontend behavior depends on deployed server state.
- `supabase_selfhost` only if UI data mismatch requires backend verification.
