# PRD: Shopee Integration, CI/CD Version Control, Subscription Plans

## Summary

Tujuan fitur berikutnya adalah menambahkan Shopee ke alur marketplace aktif,
menyiapkan kontrol versi build lewat CI/CD, dan membuat subscription plan yang
mengatur akses fitur per tenant. Scope ini tidak menjalankan SQL ke Supabase,
tidak apply cleanup, dan tidak membuat chain RPC/function baru.

## Goals

- Shopee berjalan lewat marketplace flow yang sama seperti provider existing.
- Order Shopee bisa ditarik, status non-completed bisa diperbarui, dan data
  masuk ke halaman Order Marketplace, SKU Mapping, Stock Sync, Job Monitor, dan
  Refund/Cancel Monitor.
- CI/CD memblokir build dengan versi tidak valid dan menghasilkan APK debug
  untuk PR serta release candidate untuk tag valid.
- Subscription plan membedakan entitlement tenant tanpa hanya bergantung pada
  hide/show UI Flutter.

## Non Goals

- Tidak membuat PATCH42.
- Tidak membuat bridge RPC.
- Tidak membuat RPC/function v90, v91, v92, atau suffix kompatibilitas baru.
- Tidak drop table dan tidak hapus data bisnis.
- Tidak apply `CLEANUP_UNUSED_FUNCTIONS_AFTER_PASS.sql`.
- Tidak mengintegrasikan payment gateway pada v1 subscription.

## Shopee Marketplace Requirements

Provider ID resmi adalah `shopee`. Flutter harus tetap memakai kontrak:

- `marketplace-auth-start`
- `marketplace-product-pull`
- `marketplace-order-pull`
- `marketplace-stock-sync-worker`
- `marketplace-order-sync-jobs`

Backend harus membaca `marketplace = shopee` dan menjalankan adapter Shopee di
balik kontrak tersebut. UI tidak perlu halaman khusus Shopee bila data provider
bisa dibaca oleh halaman marketplace existing.

Acceptance:

- Admin dan Super Admin bisa reconnect akun Shopee existing.
- Super Admin bisa tambah akun Shopee baru.
- Pull product Shopee mengisi cache produk/varian untuk mapping SKU.
- Pull order Shopee memakai recent safe window 90 hari / 3 bulan dan tidak
  membuat backlog besar.
- Refresh status tidak mengubah completed order kecuali ada aturan eksplisit.
- Refund/cancel detail menampilkan tanggal, order id, resi, status, buyer/shop,
  item list, SKU lokal/marketplace, qty, stock action status, dan alasan jika
  data tersedia. HPP tidak ditampilkan di Refund/Cancel Monitor.
- Refund/cancel pull default 90 hari, selaras dengan order dan finance view.
- Shopee callback bisa memakai Vercel sebagai halaman hasil melalui
  `MARKETPLACE_CONNECT_RESULT_URL`, sementara redirect URI Shopee tetap ke
  Supabase Edge Function.

## CI/CD And Version Control Requirements

Source of truth versi adalah `pubspec.yaml`:

```text
version: x.y.z+build
```

CI wajib:

- menjalankan `flutter pub get`
- menjalankan `flutter analyze --no-pub`
- membangun APK debug
- memvalidasi format versi

Release candidate wajib:

- jalan hanya untuk tag `vX.Y.Z+N`
- memvalidasi tag sama dengan versi `pubspec.yaml`
- membangun APK release dan AAB release
- memakai signing secret bila tersedia

Secrets release Android:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

## Subscription Requirements

Plan default untuk clone `mobile_erp`:

| Plan | WMS/Barcode | Marketplace | Produksi | Finance | Export/Audit |
| --- | --- | --- | --- | --- | --- |
| wms | yes | no | no | no | stock export only |
| finance | no | no | no | yes | finance export |
| full | yes | yes | yes | yes | yes |

Entitlement yang harus dikontrol:

- user seat limit
- marketplace account limit
- SKU limit
- monthly order sync limit
- marketplace account/reconnect
- order pull
- stock sync
- refund/cancel monitor
- finance report
- auto finance
- auto order pull
- job monitor
- analytics
- export/import
- audit center
- super settings

Flutter boleh menyembunyikan menu untuk UX, tetapi backend tetap harus validasi
entitlement untuk action berbiaya/berisiko seperti auto pull, finance, export,
dan marketplace account limit.

## Data And Backend Notes

Subscription schema harus additive. Draft baseline boleh memakai tabel baru:

- `subscription_plans`
- `tenant_subscriptions`
- `feature_entitlements`
- `usage_counters`

RLS harus aktif untuk tabel public. Client tidak boleh menerima service role.
Semua backend enforcement harus menggunakan tenant dari session/auth context
atau parameter tervalidasi yang sudah ada di flow active.

## Rollout

1. Merge CI/version guard dulu.
2. Tambahkan dokumentasi kontrak marketplace dan adapter Shopee di backend
   source-of-truth.
3. Aktifkan Shopee sandbox/testing account.
4. Smoke test Shopee product/order/stock/refund.
5. Tambahkan subscription schema secara additive di environment staging.
6. Gate Flutter dan backend per entitlement.
7. Baru siapkan production rollout.

## Success Metrics

- Shopee order hari ini muncul di Order Marketplace.
- Status order Shopee non-completed berubah sesuai data marketplace terbaru.
- Tidak ada backlog ratusan/ribuan pending jobs.
- PR build otomatis menghasilkan debug APK.
- Release tag salah gagal sebelum build.
- Tenant plan rendah tidak bisa menjalankan fitur plan tinggi dari client.
