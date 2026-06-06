# Subscription Plan Matrix

This matrix defines the first `mobile_erp` subscription entitlement target. It
is a product contract, not an applied database migration.

| Feature | wms | finance | full |
| --- | --- | --- | --- |
| Plan label | WMS Only | Finance Only | Full ERP |
| Core stock/WMS | yes | no | yes |
| Barcode stock in/out | yes | no | yes |
| Stock history and low stock | yes | no | yes |
| User seats | 5 | 8 | 250 |
| SKU limit | 3000 | 0 | 100000 |
| Marketplace accounts | 0 | 0 | 50 |
| Monthly order sync | 0 | 0 | 500000 |
| Marketplace account/reconnect | no | no | yes |
| Marketplace order pull | no | no | yes |
| SKU mapping | no | no | yes |
| Stock sync | no | no | yes |
| Refund/cancel monitor | no | no | yes |
| Production | no | no | yes |
| Purchase/material | basic supplier only | purchase verification | yes |
| Finance report | no | yes | yes |
| Finance expense/payment | no | yes | yes |
| Auto finance | no | no | yes |
| Auto order pull | no | no | yes |
| Job monitor | no | no | yes |
| Analytics | WMS analytics | finance analytics | all analytics |
| Export/import | stock export only | finance export | all export/import |
| Audit center | no | no | yes |
| Super settings | no | no | yes |

## Role Interaction

- `super_admin` can open super-level controls only on `full`.
- `admin` can operate marketplace/account reconnect flows only on `full`.
- `finance` can access finance on `finance` and `full`.
- `warehouse` can access WMS on `wms` and `full`.
- Tenants on `finance` should not see or call local stock mutation flows except
  read-only references needed by finance reports.

## Backend Enforcement

Flutter menu gates are only UX. Backend must also validate entitlements before:

- creating or reconnecting marketplace accounts beyond plan limit
- running marketplace order pull
- running auto order pull
- running stock sync
- reading finance report
- running auto finance/payout refresh
- exporting/importing business data
- opening audit/super maintenance actions
- creating WMS stock movement on non-WMS plans
- opening production or purchase/material ledgers outside `full`
