# Deployment Guide

**Project:** Stock Role Management App (Flutter + Supabase)  
**Last Updated:** 2026-06-07  

---

## Prerequisites

| Tool | Version | Notes |
|:-----|:--------|:------|
| Flutter SDK | `>=3.27.4` | Check with `flutter --version` |
| Supabase CLI | `>=2.98.2` | Check with `supabase --version` |
| Android SDK | API 21+ | For physical device/emulator |
| ADB | Any | `C:\Users\<user>\AppData\Local\Android\Sdk\platform-tools\adb.exe` |

---

## 1. Environment Setup

Copy `.env.local` to `.env` and fill in credentials:

```bash
# Never commit .env or .env.local to git
cp .env.local .env
```

Required environment variables:
- `SUPABASE_URL` — your Supabase project URL
- `SUPABASE_ANON_KEY` — your Supabase anon/public key

> [!CAUTION]
> Never commit `.env`, `.env.local`, or any file containing Supabase secrets to Git.

---

## 2. Supabase Database Deploy

### Apply Finance Snapshot Function

```bash
# From project root
supabase db query --linked -f patch_snapshot.sql

# REQUIRED: Reload PostgREST schema after every SQL function change
supabase db query --linked "NOTIFY pgrst, 'reload schema';"
```

### Verify Deployment

```bash
# Check June 2026 summary
supabase db query --linked "select (public.finance_customer_dashboard_snapshot_v24_6_82o('2026-06-01','2026-06-30') ->> 'summary')::jsonb;"

# Check May 2026 summary  
supabase db query --linked "select (public.finance_customer_dashboard_snapshot_v24_6_82o('2026-05-01','2026-05-31') ->> 'summary')::jsonb;"
```

### Expected Values

| Period | Omzet | Payout | Settled HPP | Laba Bersih |
|:-------|:------|:-------|:------------|:------------|
| Jun 2026 | 79.620.825 | 6.312.694 | 4.263.000 | 2.049.694 |
| May 2026 | 365.440.666 | 182.045.707 | 118.816.000 | 63.229.707 |

---

## 3. Flutter App — Local Development

```bash
# Install dependencies
flutter pub get

# Run on connected device (physical or emulator)
flutter run

# Run static analysis
flutter analyze

# Hot restart (when app is running in terminal)
# Press R in the terminal running flutter run
```

---

## 4. Flutter App — Build Release

```bash
# Android APK (for sideload testing)
flutter build apk --release

# Android App Bundle (for Play Store)
flutter build appbundle --release
```

> [!NOTE]
> Release builds require a valid signing keystore. See `android/key.properties` (not committed to git).

---

## 5. ADB Utilities

```bash
# List connected devices
adb devices

# Take a screenshot
adb exec-out screencap -p > screenshot.png

# Restart app (force stop + relaunch)
adb shell am force-stop <package.name>
adb shell monkey -p <package.name> 1

# Send input tap (for automation)
adb shell input tap <x> <y>
```

---

## 6. CI/CD

GitHub Actions workflow runs on every PR to `main`:
- [`flutter-ci.yml`](../.github/workflows/flutter-ci.yml)
- Steps: checkout → setup Flutter → `flutter pub get` → `flutter analyze`

> [!NOTE]
> The CI workflow runs `flutter analyze` and will fail if there are any **errors** (not warnings). Pre-existing warnings in the codebase are tracked but not blocking.

---

## 7. Key Constraints

- **Supabase free plan** — use local cache in Flutter to reduce query count
- **90-day data limit** — finance and order data is limited to 90 days lookback from Flutter UI
- **No new RPC versions** — always patch the existing function
- **No Edge Functions** — all finance logic stays in the database
- **No UI layout refactoring** — Flutter UI structure must be preserved
