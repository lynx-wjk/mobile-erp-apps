# Marketplace Service Contracts

Dokumen lama TikTok-only sudah diganti menjadi kontrak marketplace generik.
Flutter aktif tidak boleh diarahkan lagi ke chain `marketplace-tiktok-service`
untuk integrasi baru. Provider baru seperti Shopee harus masuk lewat kontrak
yang sama agar halaman marketplace, order, SKU mapping, stock sync, job monitor,
dan refund/cancel tetap satu alur.

## Provider ID

```text
tiktok_shop
shopee
```

Gunakan `marketplace = shopee` untuk Shopee. Jangan membuat nama Flutter baru
seperti `shopee_v2`, `shopee_patch`, atau wrapper kompatibilitas baru.

## Edge Function Aktif

### `marketplace-auth-start`

Dipakai untuk connect dan reconnect akun marketplace.

```json
{
  "marketplace": "shopee",
  "store_alias": "Toko Utama",
  "auth_action": "reconnect",
  "environment": "production",
  "marketplace_account_id": "optional-existing-account-id"
}
```

Response minimal:

```json
{
  "marketplace": "shopee",
  "authorization_url": "https://...",
  "state": "...",
  "expires_at": "2026-05-28T12:00:00Z"
}
```

### `marketplace-product-pull`

Dipakai untuk menarik produk/varian remote ke cache marketplace.

```json
{
  "tenant_id": "tenant-id",
  "marketplace_account_id": "account-id",
  "marketplace": "shopee",
  "page_size": 50,
  "max_pages": 3,
  "max_products_per_run": 150,
  "clear_cache": false,
  "cursor": null
}
```

Response minimal:

```json
{
  "ok": true,
  "marketplace": "shopee",
  "products": 40,
  "variants": 80,
  "has_more": false,
  "next_cursor": null,
  "batch_count": 1,
  "message": "Produk diperbarui."
}
```

### `marketplace-order-pull`

Dipakai untuk pull order terbaru dan refresh status order non-completed.
Completed order tidak diubah kecuali backend diberi aturan eksplisit.

```json
{
  "tenant_id": "tenant-id",
  "marketplace_account_id": "account-id",
  "marketplace": "shopee",
  "days_back": 1,
  "limit": 50,
  "max_pages": 1,
  "include_update_time_search": true,
  "refresh_existing_status": true,
  "skip_completed_status_refresh": true,
  "skip_completed_order_pull": true
}
```

Response minimal:

```json
{
  "ok": true,
  "marketplace": "shopee",
  "orders": 34,
  "items": 34,
  "mapped_items": 30,
  "unmapped_items": 4,
  "warning_count": 0,
  "message": "Order diperbarui."
}
```

### `marketplace-stock-sync-worker`

Dipakai untuk proses queue sinkron stok berdasarkan SKU mapping aktif.

```json
{
  "tenant_id": "tenant-id",
  "marketplace_account_id": "account-id",
  "marketplace": "shopee",
  "limit": 20,
  "dry_run": false
}
```

### `marketplace-order-sync-jobs`

Dipakai oleh monitor job untuk melanjutkan antrean ringan.

```json
{
  "mode": "process_pending",
  "process": true,
  "enqueue": false,
  "max_jobs": 1,
  "page_size": 50,
  "max_pages": 1,
  "max_details": 50,
  "refresh_existing_status": true,
  "status_range_days": 14,
  "max_existing_orders": 80,
  "skip_completed_status_refresh": true,
  "skip_completed_order_pull": true,
  "background": true,
  "block_if_running": true
}
```

## Aturan Implementasi Shopee

- Tambahkan adapter Shopee di backend marketplace yang sama, bukan function
  Flutter baru.
- Simpan data ke tabel marketplace yang sama dengan pembeda `marketplace`.
- Pull order wajib memakai window terbaru dan aman untuk Free Plan.
- Refresh status wajib memprioritaskan order non-completed.
- SKU mapping, stock out scan, refund/cancel monitor, dan job monitor tetap
  membaca data dari tabel/view marketplace existing.
- Jangan membuat bridge RPC, nama versioned baru, table drop, atau delete data
  bisnis.
