# Gemini Prompt: UI Rebuild

Gunakan prompt ini untuk rebuild UI Flutter agar lebih user friendly tanpa
mengubah kontrak backend yang sudah aktif.

```text
Rebuild UI Flutter Operational Management Apps ini agar jauh lebih user
friendly, dengan style fun, cute, colorful, dan pixel-art accent, tetapi tetap
rapi untuk workflow operasional harian.

Konteks aplikasi:
- Aplikasi Flutter untuk stok lokal, marketplace TikTok/Shopee, order,
  produksi, finance, attendance, task, live, HR, dan content.
- Core stock adalah produk/SKU lokal. Marketplace SKU mapping hanya
  menghubungkan SKU marketplace ke SKU lokal.
- Jangan mengubah nama RPC, nama Edge Function, nama tabel, model data, atau
  service contract yang sudah ada.
- Jangan membuat kontrak baru khusus Shopee. Shopee tetap memakai kontrak
  marketplace generic yang sama.

Target navigasi:
- Desktop/tablet memakai sidebar.
- Mobile memakai bottom navigation atau drawer yang ringkas.
- Menu yang tampil harus mengikuti role user.
- Dashboard berubah menjadi menu Analytics.
- Analytics harus sesuai role masing-masing:
  - Super Admin/Admin: ringkasan semua modul dan shortcut kontrol.
  - Warehouse: stok, low stock, stock in/out, picking order, retur restock.
  - Produksi: progress produksi, deposit, sudah dibayar, belum dibayar, kasbon,
    dan stok masuk dari produksi selesai.
  - Finance: omzet, payout marketplace, biaya, laba rugi, anomali, expense.
  - Host Live/Content/HR: task dan performa sesuai role.
- Setiap analytics card harus clickable dan membuka detail list/halaman terkait.

Target visual:
- Gunakan warna cerah yang seimbang: sky blue, coral/pink, lime, violet,
  yellow, dan neutral ink.
- Pixel-art hanya sebagai aksen kecil: border, icon badge, empty state,
  section marker. Jangan membuat UI terlihat seperti game penuh.
- Hindari halaman yang terlalu gelap dan terlalu banyak card bertumpuk.
- Layout harus scan-friendly untuk operasional: tabel/list tetap padat,
  filter jelas, tombol utama mudah ditemukan.
- Gunakan ikon untuk aksi umum: scan, refresh, upload, filter, edit, delete,
  detail, sync, calendar.

Prioritas UX:
- Refund/Cancel Monitor harus menonjolkan scan resi, cek per item, scan produk,
  kondisi barang, bisa restock/tidak, dan submit review.
- Produksi Berjalan harus menonjolkan deposit awal global, pembayaran penjahit,
  belum bayar, kasbon, filter penjahit, dan progress stage.
- Order Marketplace harus default 3 bulan, punya filter toko/status/search, dan
  detail order mudah dibuka.
- Finance harus default 3 bulan, punya shortcut 90 hari, dan analytics detail
  mudah dibaca.
- Shopee/TikTok account connect harus jelas: status koneksi, reconnect, dan
  instruksi jika perlu authorize ulang.

Constraint teknis:
- Pertahankan semua import/service/RPC yang sudah dipakai.
- Jangan rename route/page class tanpa update semua caller.
- Jangan menghapus role permission.
- Jangan menghapus fallback error handling.
- Jangan menampilkan HPP di Refund/Cancel Monitor.
- Jangan membuat stock masuk retur tanpa submit review existing.

Output yang diinginkan:
- Refactor komponen UI reusable secukupnya.
- Sidebar shell + role analytics landing.
- Perbaikan halaman prioritas: Analytics, Marketplace Accounts, Order
  Marketplace, Refund/Cancel Monitor, Produksi Berjalan, Finance Report.
- Pastikan `flutter analyze --no-fatal-infos --no-fatal-warnings` tetap lolos.
```
