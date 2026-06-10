# Marketplace Bootstrap Permanent Worker v10 Patch

This patch updates existing Edge Function:

`supabase/functions/marketplace-order-sync-jobs/index.ts`

It does not add a new Edge Function.

## What it fixes

- Reads bootstrap payload correctly:
  - `max_pages_per_window`
  - `page_size`
  - `max_details`
  - `target_statuses`
- Bootstrap jobs default to `page_size=50`, `max_pages=5`.
- Bootstrap jobs are processed single-flight to avoid timeout/overlap.
- Running bootstrap jobs locked for more than 3 minutes are reset to retry before claim.
- Claim is now guarded with status condition, reducing duplicate worker overlap.
- Fallback small request is disabled for bootstrap jobs, preventing false `done` with 1 page.
- If bootstrap hits page capacity, worker queues smaller split child windows.
- Retryable bootstrap errors such as 502/503/504/timeout stay retry longer before becoming failed.

## Not touched

- Finance formula
- HPP logic
- Abnormal logic
- Finance RPC
- Marketplace order-pull
- Marketplace auto-runner

## Important

Do not deploy this while the temporary helper drain is still running unless you intentionally stop the helper first.

Recommended order:
1. Let current TikTok drain finish.
2. Run final cleanup SQL to unschedule temporary helper cron.
3. Merge current v9 PR.
4. Create a new branch:
   `fix/marketplace-bootstrap-permanent-worker`
5. Apply this patch.
6. Run `node --check`/deploy review or local checks.
7. Deploy `marketplace-order-sync-jobs`.
8. Remove temporary helper function in a later cleanup PR after permanent worker is verified.

## Deployment command, only after review

```powershell
supabase functions deploy marketplace-order-sync-jobs --project-ref tllknfqoczarogizheal --no-verify-jwt
```
