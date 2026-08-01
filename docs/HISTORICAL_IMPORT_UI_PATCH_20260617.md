# Historical Import UI Patch 2026-06-17

This patch adds client-side historical import UI for marketplace exports.

## What it adds

- Marketplace Accounts page AppBar button: `Import Historical Data`
- New page:
  - `lib/features/marketplace/presentation/marketplace_historical_import_page.dart`
- New service:
  - `lib/features/marketplace/services/marketplace_historical_import_service.dart`
- Supported file types:
  - `.xlsx`
  - `.csv`
  - `.zip` containing `.xlsx` or `.csv`
- DB staging RPCs:
  - `marketplace_create_order_export_import_batch`
  - `marketplace_append_order_export_import_rows`
  - `marketplace_create_finance_income_import_batch`
  - `marketplace_append_finance_income_import_rows`

## Current behavior

The UI parses exports on the client and uploads rows into staging tables.

It does not fake payout from order data. Income/payout export is separate and must be uploaded separately.

Finalize bootstrap remains guarded through `marketplace_finalize_export_bootstrap`.
