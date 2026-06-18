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
