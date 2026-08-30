---
name: tenant-onboarding-workflow
description: >
  Standard Operating Procedure (SOP) dan alur kerja terpadu onboarding tenant baru.
  Gunakan skill ini untuk memandu konfigurasi toko baru, setup master data, HR,
  keuangan, dan integrasi marketplace dengan urutan yang benar agar terhindar dari
  anomali data (HPP 0, barcode tidak terbaca, radius absensi gagal).
---

# Tenant Onboarding & Data Integrity Workflow

## Overview
Panduan standar onboarding tenant baru untuk menjamin integritas relasional data antara modul Master Produk, Stok Gudang, Keuangan & HPP, HR/Payroll, dan Integrasi Marketplace.

## The 5-Phase Golden Path

### Fase 1: Identitas Perusahaan & Lokasi Geofence (HR Core)
1. **Atur Profil Bisnis**: Nama toko, logo, kontak resmi.
2. **Daftarkan Titik Lokasi Kerja (work_locations)**:
   - Tentukan Latitude, Longitude, dan Radius Geofence (misal: 100 meter).
   - *Penting*: Wajib dibuat sebelum karyawan melakukan absensi GPS.
3. **Konfigurasi Parameter Payroll (payroll_company_settings)**:
   - Tanggal cut-off penggajian bulanan dan multiplier jam lembur.

### Fase 2: Master Katalog Produk & Nilai Modal (HPP)
1. **Input / Import Kategori & Brand Produk**.
2. **Input Master Produk & Varian (products)**:
   - Isi kode SKU, nama barang, varian ukuran/warna, dan kode barcode.
3. **WAJIB: Isi Harga Modal Pokok (harga_hpp_default)**:
   - *Penting*: Jika HPP kosong, laporan keuangan akan mencatat profit fiktif 100%.
4. **Input Saldo Stok Awal Fisik (Initial Stock Opname)**.

### Fase 3: Keuangan Dasar & Pemasok (Finance & Procurement)
1. **Input Saldo Kas / Rekening Bank Pembukaan (inance_company_cash_opening_balances)**:
   - *Penting*: Mencegah buku kas bernilai negatif saat transaksi pengeluaran pertama.
2. **Daftarkan Master Supplier (suppliers)**:
   - Wajib sebelum membuat pesanan pembelian (Purchase Order).

### Fase 4: Integrasi Marketplace Bertahap (Safe Sync)
1. **Hubungkan Akun Toko Marketplace (marketplace_accounts)** via OAuth Shopee/TikTok.
2. **Tarik Katalog Toko Online (Catalog Pull)** untuk membuat variant snapshots.
3. **WAJIB: Jalankan SKU & HPP Mapping (marketplace_sku_maps)**:
   - Petakan setiap SKU online ke Master Produk Lokal.
4. **Verifikasi Kesiapan Integrasi**: Pastikan status toko berstatus READY.

### Fase 5: Operasional Go-Live & Daily Sync
1. **Tarik Riwayat Pesanan (marketplace_orders)**.
2. **Tarik Laporan Settlement Keuangan (marketplace_finance_reports)**.
3. **Undang Karyawan / Staff (	enant_invites)** dan tetapkan Role (Admin, Gudang, Finance, HR).
4. **Mulai Operasional Harian**: Packing scan barcode, absensi GPS, dan monitoring laba/rugi.

## Backend Progress Check
Gunakan RPC database berikut untuk mengecek status kesiapan tenant secara instan:
SELECT public.tenant_get_onboarding_progress('<tenant_id>');

## Common Mistakes & Troubleshooting
- **Kesalahan #1**: Menarik pesanan marketplace sebelum SKU Mapping selesai.
  - *Akibat*: order_items.product_id bernilai NULL, barcode packing tidak terbaca.
  - *Solusi*: Buka menu Marketplace -> SKU Mapping lalu lakukan auto-map atau manual map.
- **Kesalahan #2**: Menarik laporan keuangan sebelum mengisi HPP.
  - *Akibat*: Laba kotor = Omset (HPP terhitung Rp 0).
  - *Solusi*: Set default HPP di Master Produk, lalu jalankan Recalculate Finance Metrics.
