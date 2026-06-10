# Marketplace Bootstrap UI Status v9d

Adds repo-parity migration for live RPC:

`public.marketplace_bootstrap_ui_status_v1()`

Purpose:
- UI banner payload for marketplace 90-day bootstrap.
- Per-store progress/status.
- Includes retry/pending/running/done/failed counts.
- Includes ETA and client-friendly message.
- No Finance/HPP changes.
- No hardcoded tenant/account.
- Read-only.

Flutter call:

```dart
final result = await Supabase.instance.client.rpc('marketplace_bootstrap_ui_status_v1');

final showBanner = result['show_banner'] == true;
final title = result['title'] as String?;
final message = result['message'] as String?;
final severity = result['severity'] as String?;
final summary = result['summary'] as Map<String, dynamic>?;
final accounts = (result['accounts'] as List?) ?? [];
```

Recommended UI placement:
- Marketplace home/account page top banner.
- Finance dashboard small "Data sementara" banner while `show_banner = true`.
- Admin monitor can display per-account `technical_status`.
