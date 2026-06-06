# Shopee Callback With Vercel Result Page

Dokumen ini menjelaskan setup Shopee supaya callback tetap memakai Supabase
Edge Function, tetapi halaman hasilnya tampil lewat Vercel. Ini cocok kalau
Shopee reviewer atau browser callback kurang nyaman dengan halaman plain text.

## Current Backend

Active Supabase Edge Functions:

- `marketplace-auth-start`
- `marketplace-shopee-callback`
- `marketplace-product-pull`
- `marketplace-order-pull`
- `marketplace-stock-sync-worker`
- `marketplace-order-sync-jobs`
- `marketplace-return-refund-pull`

Provider ID Shopee tetap:

```text
shopee
```

## Current Status

Status per 2026-06-04:

- Vercel result page sudah dibuat di project baru
  `shopee-marketplace-callback-20260604`.
- Project Vercel lama `operational-management-app` tidak dipakai untuk Shopee
  callback result.
- `MARKETPLACE_CONNECT_RESULT_URL` diarahkan ke alias production:
  `https://shopee-marketplace-callback-2026060.vercel.app/marketplace-connected`
- `SHOPEE_REDIRECT_URI` sudah diarahkan ke Supabase callback.
- `SHOPEE_PARTNER_ID` dan `SHOPEE_PARTNER_KEY` sudah ada di Supabase Edge
  Function secrets. Jika credential Shopee diganti, update ulang dua secret
  ini sebelum reconnect toko.
- Callback Supabase sudah dites manual dan redirect 302 ke Vercel result page.
- Vercel result page sudah dites dan merespons 200 OK.

Callback Shopee tetap:

```text
https://tllknfqoczarogizheal.supabase.co/functions/v1/marketplace-shopee-callback
```

## Vercel Page

Halaman result tersedia di:

```text
marketplace-connected.html
web/marketplace-connected.html
vercel_deploy/marketplace-connected.html
```

Route Vercel yang disiapkan:

```text
/marketplace-connected
/marketplace-connected.html
```

Gunakan salah satu URL Vercel berikut sebagai result URL:

```text
https://shopee-marketplace-callback-2026060.vercel.app/marketplace-connected
https://shopee-marketplace-callback-2026060.vercel.app/marketplace-connected.html
https://shopee-marketplace-callback-20260604-ha-i-s-projects.vercel.app/marketplace-connected
https://<vercel-domain>/marketplace-connected
https://<vercel-domain>/marketplace-connected.html
```

## Required Supabase Secrets

Set secrets berikut di Supabase Edge Functions:

```text
SHOPEE_PARTNER_ID=<partner id dari Shopee>
SHOPEE_PARTNER_KEY=<partner key dari Shopee>
SHOPEE_REDIRECT_URI=https://tllknfqoczarogizheal.supabase.co/functions/v1/marketplace-shopee-callback
MARKETPLACE_TOKEN_ENCRYPTION_KEY=<minimal 32 karakter>
MARKETPLACE_CONNECT_RESULT_URL=https://shopee-marketplace-callback-2026060.vercel.app/marketplace-connected
```

`MARKETPLACE_CONNECT_RESULT_URL` adalah bagian Vercel workaround. Callback
Shopee akan redirect ke URL ini dengan query:

```text
status
title
message
marketplace
shop_name
shop_region
```

Halaman result tidak pernah menampilkan access token atau refresh token.

## Shopee Partner Console

Masukkan redirect/callback berikut ke whitelist Shopee Partner:

```text
https://tllknfqoczarogizheal.supabase.co/functions/v1/marketplace-shopee-callback
```

Jangan masukkan URL Vercel sebagai Shopee redirect URI. URL Vercel hanya halaman
hasil setelah Supabase callback selesai menukar token dan menyimpan akun.

## Smoke Test

1. Deploy Vercel dari folder khusus Shopee callback atau folder
   `vercel_deploy`.
2. Buka `https://shopee-marketplace-callback-2026060.vercel.app/marketplace-connected?status=success&marketplace=shopee&shop_name=Test%20Shop&shop_region=ID`.
3. Pastikan halaman menampilkan status `Connected`, marketplace `shopee`, shop,
   dan region.
4. Buka juga root `https://shopee-marketplace-callback-2026060.vercel.app/`;
   halaman harus tetap menampilkan `Marketplace Connected`, bukan Flutter blank
   page.
5. Set `MARKETPLACE_CONNECT_RESULT_URL` ke URL Vercel yang sudah lolos test.
6. Di aplikasi, buka `Akun Marketplace`.
7. Pilih Shopee, isi alias toko, lalu connect/reconnect.
8. Setelah approve di Shopee, refresh halaman `Akun Marketplace`.
9. Jalankan pull product, mapping SKU lokal, pull order, stock sync, dan
   refund/cancel monitor.

## Common Errors

- `Missing env: SHOPEE_PARTNER_ID`: secret Shopee belum diset di Supabase.
- `OAuth State Tidak Valid`: user membuka callback manual atau link auth sudah
  expired. Generate link baru dari aplikasi.
- `Shop ID Tidak Ada`: Shopee tidak mengirim `shop_id`/`main_account_id`.
- Halaman result plain text: `MARKETPLACE_CONNECT_RESULT_URL` belum diset.
