-- Phase 6C-B: Public subscription plan feature labels + public pricing RPC.
-- Scope:
-- - Add client-facing labels/descriptions for feature_catalog.
-- - Add safe public RPC list_public_subscription_plans().
-- - Do not change entitlement enforcement.
-- - Do not change marketplace/finance/cron behavior.

BEGIN;

ALTER TABLE public.feature_catalog
  ADD COLUMN IF NOT EXISTS public_label text,
  ADD COLUMN IF NOT EXISTS public_description text,
  ADD COLUMN IF NOT EXISTS is_client_visible boolean DEFAULT true;

UPDATE public.feature_catalog
SET is_client_visible = true
WHERE is_client_visible IS NULL;

ALTER TABLE public.feature_catalog
  ALTER COLUMN is_client_visible SET DEFAULT true,
  ALTER COLUMN is_client_visible SET NOT NULL;

WITH labels(feature_key, public_label, public_description, is_client_visible) AS (
  VALUES
    ('platform_owner_dashboard', 'Platform Owner Dashboard', 'Panel internal untuk pemilik platform.', false),
    ('tenant_management', 'Manajemen Client', 'Fitur internal untuk mengelola tenant/client.', false),
    ('invite_management', 'Manajemen Undangan', 'Fitur internal untuk membuat dan mengatur undangan user.', false),

    ('stock_basic', 'Stok Barang & Barcode', 'Kelola stok masuk, stok keluar, barcode, dan riwayat pergerakan barang.', true),
    ('production_basic', 'Manajemen Produksi', 'Pantau proses produksi, progress pekerjaan, dan kebutuhan operasional produksi.', true),
    ('finance_basic', 'Laporan Keuangan Dasar', 'Pantau omzet, biaya, HPP, laba rugi, dan ringkasan keuangan utama.', true),

    ('marketplace_accounts', 'Koneksi Toko Marketplace', 'Hubungkan akun Shopee dan TikTok Shop ke sistem.', true),
    ('marketplace_order_sync', 'Sinkronisasi Pesanan', 'Tarik dan pantau pesanan marketplace secara terpusat.', true),
    ('marketplace_product_sync', 'Sinkronisasi Produk & Varian', 'Tarik katalog produk, varian, SKU, dan data toko dari marketplace.', true),
    ('marketplace_stock_sync', 'Sinkronisasi Stok Otomatis', 'Sinkronkan stok lokal dengan stok marketplace secara otomatis.', true),
    ('marketplace_finance_sync', 'Sinkronisasi Settlement Keuangan', 'Tarik data settlement/payout marketplace untuk laporan keuangan.', true),
    ('marketplace_return_refund', 'Monitor Retur & Refund', 'Pantau retur, refund, pembatalan, dan status masalah pesanan.', true),
    ('marketplace_job_monitor', 'Monitor Sinkronisasi Internal', 'Monitor teknis untuk proses sinkronisasi marketplace.', false),

    ('attendance_basic', 'Absensi Karyawan', 'Catat absensi tim dengan bukti lokasi dan waktu.', true),
    ('task_basic', 'Tugas Tim', 'Buat, pantau, dan selesaikan tugas operasional harian.', true),
    ('live_schedule_basic', 'Jadwal Host Live', 'Atur jadwal host live dan sesi live harian.', true),
    ('content_task_basic', 'Tugas Konten', 'Kelola pekerjaan konten, bukti pekerjaan, dan monitoring kreator.', true),
    ('purchase_requests', 'Pengajuan Pembelian', 'Buat dan verifikasi pengajuan pembelian operasional.', true),
    ('finance_expenses', 'Biaya Operasional Detail', 'Kelola biaya operasional, pengeluaran, dan arus kas lebih detail.', true),
    ('finance_abnormal_monitor', 'Monitor Abnormal Finance', 'Deteksi payout minus dan margin rendah yang perlu dicek.', true),

    ('subscription_management', 'Manajemen Subscription & Billing', 'Fitur internal untuk mengatur paket subscription client.', false)
)
UPDATE public.feature_catalog fc
SET
  public_label = labels.public_label,
  public_description = labels.public_description,
  is_client_visible = labels.is_client_visible,
  updated_at = now()
FROM labels
WHERE fc.feature_key = labels.feature_key;

UPDATE public.feature_catalog
SET
  public_label = COALESCE(NULLIF(public_label, ''), feature_name),
  public_description = COALESCE(NULLIF(public_description, ''), description, feature_name),
  is_client_visible = COALESCE(is_client_visible, true),
  updated_at = now()
WHERE public_label IS NULL
   OR public_description IS NULL
   OR is_client_visible IS NULL;

CREATE INDEX IF NOT EXISTS idx_feature_catalog_public_visible_sort
  ON public.feature_catalog(is_active, is_client_visible, sort_order);

CREATE OR REPLACE FUNCTION public.list_public_subscription_plans()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_plans jsonb;
BEGIN
  SELECT COALESCE(
    jsonb_agg(plan_row.plan_payload ORDER BY plan_row.plan_sort_order, plan_row.plan_code),
    '[]'::jsonb
  )
  INTO v_plans
  FROM (
    SELECT
      sp.sort_order AS plan_sort_order,
      sp.plan_code,
      jsonb_build_object(
        'plan_code', sp.plan_code,
        'plan_name', sp.plan_name,
        'description', sp.description,
        'billing_period', sp.billing_period,
        'price_amount', sp.price_amount,
        'currency', sp.currency,
        'max_users', sp.max_users,
        'max_marketplace_accounts', sp.max_marketplace_accounts,
        'max_shopee_accounts', sp.max_shopee_accounts,
        'max_tiktok_accounts', sp.max_tiktok_accounts,
        'max_storage_mb', sp.max_storage_mb,
        'max_order_retention_days', sp.max_order_retention_days,
        'is_trial', sp.is_trial,
        'sort_order', sp.sort_order,
        'features', COALESCE(
          (
            SELECT jsonb_agg(feature_row.feature_payload ORDER BY feature_row.feature_sort_order, feature_row.feature_key)
            FROM (
              SELECT
                fc.sort_order AS feature_sort_order,
                fc.feature_key,
                jsonb_build_object(
                  'feature_key', fc.feature_key,
                  'label', COALESCE(NULLIF(fc.public_label, ''), fc.feature_name),
                  'description', COALESCE(NULLIF(fc.public_description, ''), fc.description, fc.feature_name),
                  'feature_group', fc.feature_group,
                  'limit_value', spf.limit_value,
                  'sort_order', fc.sort_order
                ) AS feature_payload
              FROM public.subscription_plan_features spf
              JOIN public.feature_catalog fc
                ON fc.feature_key = spf.feature_key
              WHERE spf.plan_id = sp.plan_id
                AND spf.enabled = true
                AND fc.is_active = true
                AND fc.is_client_visible = true
            ) feature_row
          ),
          '[]'::jsonb
        )
      ) AS plan_payload
    FROM public.subscription_plans sp
    WHERE sp.is_active = true
  ) plan_row;

  RETURN jsonb_build_object(
    'ok', true,
    'version', 'phase_6c_b_public_subscription_plans',
    'generated_at', now(),
    'plans', v_plans
  );
END;
$$;

ALTER FUNCTION public.list_public_subscription_plans() OWNER TO postgres;

REVOKE ALL ON FUNCTION public.list_public_subscription_plans() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_public_subscription_plans() TO anon;
GRANT EXECUTE ON FUNCTION public.list_public_subscription_plans() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_public_subscription_plans() TO service_role;

COMMENT ON FUNCTION public.list_public_subscription_plans()
IS 'Public-safe subscription plan catalog for pricing/request-access screens. Exposes active plans and client-visible feature labels only.';

COMMIT;
