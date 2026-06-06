# Release And Version Control

## Version Source Of Truth

The app version is controlled by `pubspec.yaml`.

```yaml
version: 1.0.0+1
```

Use this format:

```text
major.minor.patch+build
```

For release tags, use the exact version with a leading `v`:

```text
v1.0.0+1
```

`android/local.properties` is local machine state only. Do not use it as the
release version source.

## Pull Request Gate

The Flutter CI workflow runs:

```bash
bash scripts/validate_flutter_version.sh
flutter pub get
flutter analyze --no-pub
flutter build apk --debug --no-pub
```

On Windows/PowerShell, use:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/validate_flutter_version.ps1
```

The debug APK is uploaded as a workflow artifact.

## Web Production Deploy

The `Vercel Web Deploy` workflow builds Flutter web and deploys to:

```text
https://operational-management-app-two.vercel.app/
```

Required GitHub Secrets:

- `VERCEL_TOKEN`
- `VERCEL_ORG_ID`
- `VERCEL_PROJECT_ID`

The workflow keeps the Shopee callback result page available by copying
`marketplace-connected.html` into `build/web` before deployment. It also copies
`vercel.json`, so `/marketplace-connected` and `/marketplace-connected.html`
continue to route to the callback result page while `/` opens the Flutter app.

## Release Candidate Gate

Create a release tag that exactly matches `pubspec.yaml`.

```bash
git tag v1.0.0+2
git push origin v1.0.0+2
```

The Android release candidate workflow builds:

- release APK
- release AAB

## Android Signing Secrets

Configure these GitHub Secrets before production release:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

If secrets are not configured, local release builds fall back to debug signing
for development convenience. Production release must use a real upload key.

## Rollback

1. Keep the previous release artifact.
2. If a release fails smoke testing, do not promote it.
3. Re-tag only after bumping `pubspec.yaml` to a newer build number.
4. For database-related releases, never run cleanup SQL until the active app
   smoke test has passed.
