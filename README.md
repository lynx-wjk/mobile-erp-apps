# Operational Management Apps

Flutter app for stock, marketplace, order, finance, attendance, and operational
management.

## Active Notes

- App version source of truth: `pubspec.yaml`.
- Android release signing is configured through GitHub Secrets when running CI.
- Marketplace providers use the generic marketplace contracts documented in
  `docs/MARKETPLACE_SERVICE_CONTRACTS.md`.
- Shopee planning, CI/CD controls, and subscription entitlement requirements are
  documented in `docs/PRD_SHOPEE_CICD_SUBSCRIPTION.md`.
- Shopee callback result page and Vercel workaround are documented in
  `docs/SHOPEE_VERCEL_CALLBACK_SETUP.md`.
- Cleanup SQL must not be applied until finance/order smoke tests pass.

## Common Checks

```bash
flutter pub get
flutter analyze --no-pub
flutter build apk --debug --no-pub
```
