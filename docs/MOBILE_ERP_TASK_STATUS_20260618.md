# MOBILE ERP Task Status

## Selesai
- Self-host Supabase aktif dan app terhubung.
- Reauth marketplace aktif untuk Shopee dan TikTok.
- Historical import order dan income selesai untuk Shopee.
- Historical import order dan income selesai untuk TikTok.
- Finalize historical import ke tabel live selesai untuk Shopee dan TikTok.
- Product snapshot dan variant snapshot sudah bisa masuk dari product pull smoke.
- Order dispatcher incremental smoke pernah berhasil 200.
- Finance dispatcher incremental smoke pernah berhasil 200 ketika tidak ada window pending.
- Tombol Export SKU Mapping, Import SKU Mapping, Sync HPP dari Mapping, dan Refresh Finance sudah muncul di SKU Mapping.
- Fast order list RPC sudah dibuat untuk mengganti query order page yang berat.

## Sedang berjalan
- Stabilkan Order Marketplace agar tidak fallback ke view lama.
- Stabilkan Product Pull agar tidak merah saat Edge worker menghentikan request panjang.
- Recovery SKU/HPP setelah historical import yang dilakukan sebelum mapping.
- Validasi ulang Finance setelah SKU mapping dan HPP mapping terisi.

## Belum selesai
- Mapping SKU marketplace ke SKU lokal untuk akun Shopee dan TikTok baru.
- Populate HPP mapping dari SKU mapping.
- Finance dashboard policy final: omzet by order date, payout by settlement/release date, HPP by mapping.
- Perbaiki Finance supaya tidak menampilkan margin/laba seolah valid ketika HPP mapping kosong.
- Tambah analytics finance card di Dashboard Analytics Web.
- Buat page monitoring job marketplace yang ringkas dan tidak menumpang di Finance.
- Cleanup RPC lama yang tidak dipakai setelah dependency audit.
- Cleanup wording tidak profesional/satire/sarkas di semua UI, docs, dan source.
- Audit refresh-token path untuk product/order/finance Shopee dan TikTok.
- Validasi order status update dan payout update setelah cron berjalan normal.
- Validasi stock sync real API setelah mapping SKU dan marketplace sku id lengkap.
- Rapikan repo: commit target file, abaikan audit/tmp, jangan commit logs.

## 2026-06-18 Product Pull Cursor Fix
- Product pull endpoint supports cursor-based paging for Shopee.
- Product pull endpoint returns has_more and next_cursor to Flutter.
- Product pull no longer clears old snapshots on each partial pull.
- Flutter product pull loops up to 40 small batches with 5 products per request.

## 2026-06-19 Finance Reconciliation
- Added finance_marketplace_reconciliation_breakdown RPC.
- Sample/free/zero-payment orders are exposed as Finance abnormal rows.
- Profit/loss can show gross-to-payout adjustment breakdown: voucher/discount, marketplace fee, tax, refund/return/cancel, sample/zero-payment, and unclassified adjustment.
- Finance page merges reconciliation breakdown after loading the main finance snapshot.

## 2026-06-19 Finance Sample Card + Marketplace Breakdown
- Ringkasan Finance now has a Sample / Gratis card with order count, sample HPP, sample negative payout, and estimated impact.
- Reconciliation now returns by_marketplace rows so Shopee and TikTok appear separately in the Marketplace tab.
- Payout total is scoped by selected order period through order-key matching, preventing 90-day imported TikTok payout from inflating the current-month view.

## 2026-06-19 Finance Sample Card + Marketplace Breakdown
- Ringkasan Finance has a Sample / Gratis card with order count, sample HPP, sample negative payout, and estimated impact.
- Reconciliation returns by_marketplace rows so Shopee and TikTok appear separately in the Marketplace tab.
- Reconciliation function is volatile because it uses temporary tables for scoped period calculations.

## 2026-06-19 Finance Sample Card + Marketplace Breakdown
- Ringkasan Finance has a Sample / Gratis card with order count, sample HPP, sample negative payout, and estimated impact.
- Reconciliation returns by_marketplace rows so Shopee and TikTok appear separately in the Marketplace tab.
- Reconciliation function is volatile because it uses temporary tables for scoped period calculations.

## 2026-06-19 Finance UI + Detailed Marketplace Breakdown
- Bumped Finance local cache key to avoid old 1.2B TikTok payout flash before reconciliation loads.
- Finance reconciliation now returns detailed gross-to-payout breakdown: voucher/discount, marketplace fee, refund, tax, adjustment, sample, and unclassified.
- Finance Marketplace tab uses reconciliation by_marketplace rows directly when available, so Shopee and TikTok remain separate.
