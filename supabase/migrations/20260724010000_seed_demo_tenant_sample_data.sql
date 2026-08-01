-- Migration: Seed Demo Tenant Sample Data & Role Cleanup
-- Description: Assigns demo users to existing Demo Tenant (93f3372f-59dd-4e7c-ba4f-c146f622611c), converts demo_super_admin to super_admin, and creates an idempotent sample data seeder function.

-- 1. Ensure existing Demo Tenant exists in app_tenants
INSERT INTO public.app_tenants (
    tenant_id,
    tenant_code,
    tenant_name,
    owner_name,
    owner_email,
    status,
    notes
)
VALUES (
    '93f3372f-59dd-4e7c-ba4f-c146f622611c'::uuid,
    'reviewer_demo',
    'Reviewer Demo Tenant',
    'Marketplace Reviewer',
    'demo@acc.com',
    'active',
    'Safe demo tenant with realistic sample dataset for features demo.'
)
ON CONFLICT (tenant_id) DO UPDATE
SET tenant_name = 'Reviewer Demo Tenant',
    status = 'active';

-- 2. Convert demo_super_admin users to standard super_admin scoped to Demo Tenant
UPDATE public.users
SET role_id = 'super_admin',
    tenant_id = '93f3372f-59dd-4e7c-ba4f-c146f622611c'::uuid,
    is_demo_account = true
WHERE role_id = 'demo_super_admin' OR email = 'demo@acc.com';

-- 3. Idempotent Demo Tenant Sample Data Seeder Function
CREATE OR REPLACE FUNCTION public.seed_demo_tenant_sample_data(
    p_tenant_id UUID DEFAULT '93f3372f-59dd-4e7c-ba4f-c146f622611c'::uuid
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_work_loc_id UUID;
    v_studio_loc_id UUID;
    v_supplier_1_id UUID;
    v_supplier_2_id UUID;
    v_user_admin_id UUID;

    v_prod_tshirt_id UUID;
    v_prod_hoodie_id UUID;
    v_prod_cargo_id UUID;
    v_prod_denim_id UUID;

    v_purch_1_id UUID;
    v_purch_2_id UUID;
    v_progress_1_id UUID;
    v_progress_2_id UUID;
BEGIN
    -- A. Cleanup existing demo data for this tenant
    DELETE FROM public.attendance_logs WHERE tenant_id = p_tenant_id;
    DELETE FROM public.attendance WHERE tenant_id = p_tenant_id;
    DELETE FROM public.user_work_schedules WHERE user_id IN (SELECT user_id FROM public.users WHERE tenant_id = p_tenant_id);
    DELETE FROM public.content_tasks WHERE tenant_id = p_tenant_id;
    DELETE FROM public.live_schedules WHERE tenant_id = p_tenant_id;
    DELETE FROM public.finance_verifications WHERE tenant_id = p_tenant_id;
    DELETE FROM public.production_progress_items WHERE progress_id IN (SELECT progress_id FROM public.production_progress WHERE tenant_id = p_tenant_id);
    DELETE FROM public.production_progress WHERE tenant_id = p_tenant_id;
    DELETE FROM public.purchase_items WHERE purchase_id IN (SELECT purchase_id FROM public.purchases WHERE tenant_id = p_tenant_id);
    DELETE FROM public.purchases WHERE tenant_id = p_tenant_id;
    DELETE FROM public.stock_transactions WHERE tenant_id = p_tenant_id;
    DELETE FROM public.product_costs WHERE tenant_id = p_tenant_id;
    DELETE FROM public.products WHERE tenant_id = p_tenant_id;
    DELETE FROM public.suppliers WHERE tenant_id = p_tenant_id;
    DELETE FROM public.work_locations WHERE tenant_id = p_tenant_id;

    -- B. Insert Work Locations
    v_work_loc_id := gen_random_uuid();
    v_studio_loc_id := gen_random_uuid();

    INSERT INTO public.work_locations (
        location_id, tenant_id, nama_lokasi, latitude, longitude, radius_meter, alamat, catatan, status
    ) VALUES 
    (v_work_loc_id, p_tenant_id, 'Gudang Utama Jakarta', -6.175392, 106.827153, 150, 'Jl. Industri Kebon Jeruk No. 88, Jakarta Barat', 'Pusat Distribusi & Pergudangan Utama', 'active'),
    (v_studio_loc_id, p_tenant_id, 'Studio Live & Konten Bandung', -6.917464, 107.619123, 100, 'Jl. Riau No. 45, Bandung', 'Studio Broadcasting TikTok & Shopee Live', 'active');

    -- C. Demo Admin User (bound to auth.users ID)
    v_user_admin_id := '6eb603da-5847-4712-977b-d5fad699b96b'::uuid;

    UPDATE public.users
    SET tenant_id = p_tenant_id,
        role_id = 'super_admin',
        is_demo_account = true,
        status = 'active',
        nama = 'Demo Super Admin'
    WHERE user_id = v_user_admin_id;

    -- D. Insert Suppliers
    v_supplier_1_id := gen_random_uuid();
    v_supplier_2_id := gen_random_uuid();

    INSERT INTO public.suppliers (supplier_id, tenant_id, nama_supplier, kontak_person, nomor_hp, alamat, status) VALUES
    (v_supplier_1_id, p_tenant_id, 'PT Kain Textile Nusantara', 'Haji Irfan', '081299887766', 'Kawasan Industri Textile Majalaya, Bandung', 'active'),
    (v_supplier_2_id, p_tenant_id, 'CV Aksesoris Garmen Bandung', 'Pak Joko', '081388776655', 'Jl. Cigondewah Hilir No. 12, Bandung', 'active');

    -- E. Insert Products & Variants
    v_prod_tshirt_id := gen_random_uuid();
    v_prod_hoodie_id := gen_random_uuid();
    v_prod_cargo_id := gen_random_uuid();
    v_prod_denim_id := gen_random_uuid();

    INSERT INTO public.products (
        product_id, tenant_id, kode_sku, nama_barang, kategori, harga_hpp_default, stock_saat_ini, low_stock_limit, status
    ) VALUES
    (v_prod_tshirt_id, p_tenant_id, 'TSH-OVR-01', 'T-Shirt Oversize Cotton Combed 30s', 'Apparel', 45000, 250, 20, 'active'),
    (v_prod_hoodie_id, p_tenant_id, 'HD-FLC-01', 'Hoodie Fleece Heavyweight 330gsm', 'Outerwear', 110000, 120, 15, 'active'),
    (v_prod_cargo_id, p_tenant_id, 'CG-PNT-01', 'Cargo Pants Canvas Tactical', 'Pants', 95000, 85, 10, 'active'),
    (v_prod_denim_id, p_tenant_id, 'DNM-JKT-01', 'Denim Jacket Vintage Washer', 'Outerwear', 155000, 45, 10, 'active');

    -- F. Insert Stock Transactions
    INSERT INTO public.stock_transactions (
        stock_transaction_id, tenant_id, product_id, user_id, role_id, transaction_type, jenis_transaksi, qty, stock_before, stock_after, catatan, created_at
    ) VALUES
    (gen_random_uuid(), p_tenant_id, v_prod_tshirt_id, v_user_admin_id, 'super_admin', 'IN', 'Penerimaan Supplier', 300, 0, 300, 'Penerimaan stok awal dari PO #101', CURRENT_TIMESTAMP - INTERVAL '5 days'),
    (gen_random_uuid(), p_tenant_id, v_prod_tshirt_id, v_user_admin_id, 'super_admin', 'OUT', 'Penjualan Shopee', 50, 300, 250, 'Fulfillment Order Shopee #SP-99201', CURRENT_TIMESTAMP - INTERVAL '2 days'),
    (gen_random_uuid(), p_tenant_id, v_prod_hoodie_id, v_user_admin_id, 'super_admin', 'IN', 'Hasil Produksi', 150, 0, 150, 'Stok masuk dari Batch Produksi #202', CURRENT_TIMESTAMP - INTERVAL '4 days'),
    (gen_random_uuid(), p_tenant_id, v_prod_hoodie_id, v_user_admin_id, 'super_admin', 'OUT', 'Penjualan TikTok', 30, 150, 120, 'Fulfillment Order TikTok Live Sale', CURRENT_TIMESTAMP - INTERVAL '1 day');

    -- G. Insert Purchases & Purchase Items
    v_purch_1_id := gen_random_uuid();
    v_purch_2_id := gen_random_uuid();

    INSERT INTO public.purchases (
        purchase_id, tenant_id, nomor_pembelian, supplier_id, user_id, total_pembelian, status, catatan, created_at
    ) VALUES
    (v_purch_1_id, p_tenant_id, 'PO-DEMO-001', v_supplier_1_id, v_user_admin_id, 45000000, 'approved', 'Pembelian Bahan Kain Cotton Combed 30s Black (100 Roll)', CURRENT_TIMESTAMP - INTERVAL '10 days'),
    (v_purch_2_id, p_tenant_id, 'PO-DEMO-002', v_supplier_2_id, v_user_admin_id, 12500000, 'submitted', 'Pembelian Aksesoris Resleting YKK & Label Brand Woven', CURRENT_TIMESTAMP - INTERVAL '3 days');

    INSERT INTO public.purchase_items (
        purchase_item_id, purchase_id, nama_barang, qty, harga_per_item
    ) VALUES
    (gen_random_uuid(), v_purch_1_id, 'Kain Cotton Combed 30s Black', 100, 450000),
    (gen_random_uuid(), v_purch_2_id, 'Resleting YKK Metal #5', 2500, 4000),
    (gen_random_uuid(), v_purch_2_id, 'Label Woven Premium', 5000, 500);

    -- H. Insert Production Progress
    v_progress_1_id := gen_random_uuid();
    v_progress_2_id := gen_random_uuid();

    INSERT INTO public.production_progress (
        progress_id, tenant_id, product_id, product_name, sku, qty, user_id, status, created_by, created_at
    ) VALUES
    (v_progress_1_id, p_tenant_id, v_prod_tshirt_id, 'T-Shirt Oversize Cotton Combed 30s', 'TSH-OVR-01', 500, v_user_admin_id, 'progress', v_user_admin_id, CURRENT_TIMESTAMP - INTERVAL '7 days'),
    (v_progress_2_id, p_tenant_id, v_prod_hoodie_id, 'Hoodie Fleece Heavyweight 330gsm', 'HD-FLC-01', 200, v_user_admin_id, 'done', v_user_admin_id, CURRENT_TIMESTAMP - INTERVAL '12 days');

    -- I. Insert Finance Verifications
    INSERT INTO public.finance_verifications (
        finance_verification_id, tenant_id, purchase_id, verified_by, status, catatan, verified_at
    ) VALUES
    (gen_random_uuid(), p_tenant_id, v_purch_1_id, v_user_admin_id, 'approved', 'Verifikasi pembayaran PO #1 Kain Cotton Combed', CURRENT_TIMESTAMP - INTERVAL '8 days');

    -- J. Insert Live Schedules
    INSERT INTO public.live_schedules (
        live_schedule_id, tenant_id, user_id, host_id, platform, shift, sesi, tanggal, jam_mulai, jam_selesai, status, title, created_at
    ) VALUES
    (gen_random_uuid(), p_tenant_id, v_user_admin_id, v_user_admin_id, 'TikTok', 'Malam', 'Sesi 1', CURRENT_DATE, '19:00:00', '22:00:00', 'verified', 'TikTok Flash Sale Payday Collection', CURRENT_TIMESTAMP - INTERVAL '1 day'),
    (gen_random_uuid(), p_tenant_id, v_user_admin_id, v_user_admin_id, 'Shopee', 'Siang', 'Sesi 2', CURRENT_DATE + INTERVAL '1 day', '14:00:00', '17:00:00', 'scheduled', 'Shopee Live Fashion Mid Month', CURRENT_TIMESTAMP);

    -- K. Insert Content Tasks
    INSERT INTO public.content_tasks (
        content_task_id, tenant_id, assigned_to, creator_id, title, judul_konten, platform, status, due_date, created_at
    ) VALUES
    (gen_random_uuid(), p_tenant_id, v_user_admin_id, v_user_admin_id, 'Teaser Video', 'Video Teaser New Collection Hoodie', 'TikTok', 'approved', CURRENT_DATE + INTERVAL '2 days', CURRENT_TIMESTAMP - INTERVAL '3 days'),
    (gen_random_uuid(), p_tenant_id, v_user_admin_id, v_user_admin_id, 'Style Guide', 'Reels Style Guide Cargo Pants', 'Instagram', 'in_progress', CURRENT_DATE + INTERVAL '4 days', CURRENT_TIMESTAMP - INTERVAL '1 day');

    -- L. Insert Attendance & Logs
    INSERT INTO public.attendance (
        attendance_id, tenant_id, user_id, user_name, user_email, date, check_in_time, check_out_time, check_in_distance_meter, check_out_distance_meter, status, note, created_at
    ) VALUES
    (gen_random_uuid(), p_tenant_id, v_user_admin_id, 'Demo Super Admin', 'demo@acc.com', CURRENT_DATE, CURRENT_TIMESTAMP - INTERVAL '8 hours', CURRENT_TIMESTAMP - INTERVAL '1 hour', 12, 18, 'valid', 'Presensi tepat waktu gudang demo', CURRENT_TIMESTAMP - INTERVAL '8 hours');

    -- M. Insert User Work Schedules
    DELETE FROM public.user_work_schedules WHERE user_id = v_user_admin_id;

    INSERT INTO public.user_work_schedules (user_id, day_of_week, start_time, end_time, late_tolerance_minutes, timezone, is_active)
    SELECT v_user_admin_id, d.day, '08:00', '17:00', 15, 'Asia/Jakarta', CASE WHEN d.day BETWEEN 1 AND 5 THEN true ELSE false END
    FROM (SELECT generate_series(0, 6) AS day) d;

END;
$$;

-- 4. Execute sample data seeder for Reviewer Demo Tenant
SELECT public.seed_demo_tenant_sample_data('93f3372f-59dd-4e7c-ba4f-c146f622611c'::uuid);
