# Original User Request

## 2026-08-16T16:17:39Z

Re-engineer the Mobile ERP landing page (https://mdhproduction.com) based strictly on a 100% truthful, exhaustive scan of all operational modules in lib/features/ (WMS, OMS, FMS, HRIS & Payroll, Live Host, Produksi Konveksi, Purchasing, Tasks), completely eliminating all fabricated/hallucinated claims (no fake logistics contracts; clarify tracking is via Shopee/TikTok APIs; no fake face recognition AI; state GPS radius + selfie photo verification), excluding all Platform Owner features, localizing the headquarters to Bandung, Indonesia, and applying Tier-1 enterprise craftsmanship following UI/UX Pro Max guidelines.

Working directory: c:\Users\budic\Downloads\android\inventory_control_apps\landing_page
Integrity mode: development

## Requirements

### R1. 100% Truthful Feature Mapping from Codebase (lib/features/)
Audit and represent every operational feature that genuinely exists in the application:
- **WMS (Warehouse Management System)**: Multi-Gudang (Pusat, Toko, Retur), Inbound/Outbound Scan Barcode Kamera HP (mobile_scanner), Kartu Stok Digital, Stock Opname, Low Stock Alert (Reorder Point / ROP).
- **OMS (Omnichannel Management System)**: Integrasi Resmi Shopee Open Platform & TikTok Shop Partner API, Sinkronisasi Stok Otomatis Antar Toko, Centralized Order Queue, Pemetaan SKU & Varian Produk, Scan Resi & Packing Otomatis, Manajemen Retur & Refund Komplain. (Zero Hallucination: Tracking kurir SPX, J&T, SiCepat, Anteraja ditarik langsung dari integrasi API Shopee & TikTok Shop, bukan kemitraan ekspedisi langsung).
- **FMS (Financial Management System)**: Rekonsiliasi Otomatis Pencairan Dana (Escrow Settlement) tiap 10 Menit dari Shopee & TikTok, Deteksi Anomaly Payout Minus & Biaya Admin, Kalkulator Margin & HPP per SKU, Pencatatan Kas Keluar & Biaya Operasional Toko, Buku Kas Digital & Laporan Tutup Buku Bulanan (Export PDF/Excel).
- **HRIS & Penggajian (Payroll)**: Absensi Karyawan berbasis Geotagging GPS Radius Kantor + Bukti Foto Selfie Kamera HP (Zero Hallucination: Bukan face recognition AI; murni GPS Geofencing + Selfie Kamera), Manajemen Shift Kerja, Pengajuan Lembur & Izin, Slip Gaji Digital Terenkripsi dengan Komponen Tunjangan, Komisi, dan Potongan Absen.
- **Live Host & Stream Operations**: Penjadwalan Shift Host Live TikTok / Shopee, Upload & Verifikasi Bukti Siaran Live Stream, Skema Komisi Host Live berbasis Omzet Penjualan Live & Durasi.
- **Manajemen Produksi Konveksi / Garmen**: Surat Perintah Kerja (SPK) Penjahit/Tailor, Monitoring 5 Tahapan Produksi (Cutting -> Sewing -> Finishing -> QC -> Gudang), Perhitungan Upah Borongan per Pcs, Kontrol Bahan Baku & Cacat Produksi.
- **Supplier & Pengajuan Pembelian (Purchasing)**: Direktori Supplier, Form Pengajuan Pembelian Stok/Bahan (Purchase Request), Verifikasi Nota & Bukti Bayar Pembelian.
- **Tugas Tim & Manajemen Konten**: Delegasi Tugas Harian Staf, Monitoring Timeline & Konten Kreator Media Sosial.
- **Enterprise Security (EMS)**: Isolasi Data Multi-Tenant PostgreSQL RLS, Role-Based Access Control (Super Admin Tenant, Admin Gudang, Admin Keuangan, Host Live, Penjahit, Staf), Backup Database Harian, Enkripsi Token AES-GCM.

### R2. Strict Exclusion of Platform Owner Features
- Do NOT expose or mention Platform Owner features (super admin database raw tools, platform billing management, tenant deletion audit) in any public marketing copy, interactive demos, or feature lists.
- Focus strictly on tenant business roles: Super Admin Tenant, Admin Gudang, Admin Keuangan, Host Live, Penjahit, dan Staf Operasional.

### R3. Accurate Bandung, Indonesia Localization & Metadata
- Update all location mentions, postal addresses, geo coordinates, metadata, JSON-LD schemas, and OpenGraph tags from Jakarta to Bandung, Indonesia (Jawa Barat, Indonesia).
- Official direct contacts: WhatsApp 085155338246 and Email bdchydi@sre.co.id.

### R4. UI/UX Pro Max Visual Craftsmanship
- Deep obsidian aesthetic (#080C14 / #0D1322), micro-borders (rgba(255, 255, 255, 0.07)), and custom metallic logo (assets/logo.png).
- Tight typography hierarchy (Outfit headings + Plus Jakarta Sans body), flawless icon scale alignment (.material-symbols-outlined), responsive mobile layout, and interactive demonstrator tabs showcasing real ERP workflows without artificial fluff.

## Acceptance Criteria

### Truthful Feature Representation
- [ ] 0 occurrences of fake logistics contracts (clearly attributed to Shopee & TikTok API tracking).
- [ ] 0 occurrences of facial recognition AI claims (clearly described as GPS Geofencing + Kamera Selfie).
- [ ] Every operational module in lib/features/ (WMS, OMS, FMS, HRIS/Payroll, Live Host, Produksi Konveksi, Purchasing, Tasks) is represented.
- [ ] 0 mentions of Platform Owner features in public marketing sections.

### Localization & Contact Verification
- [ ] Location across Schema.org, meta tags, and footer displays Bandung, Indonesia (Jawa Barat).
- [ ] Direct WhatsApp consultation triggers link to 085155338246 and email to bdchydi@sre.co.id.

### Code & Production Readiness
- [ ] landing_page/index.html, styles.css, and app.js are updated and uploaded to /var/www/landing_page/ on VPS.
- [ ] https://mdhproduction.com/ returns HTTP 200 OK with valid sitemap and robots.txt.
