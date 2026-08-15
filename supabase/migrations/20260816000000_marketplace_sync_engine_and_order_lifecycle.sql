-- Migration: Marketplace Sync Engine, Stale Order Lifecycle Auto-Progression, and 90-Day Retention
-- Migration ID: 20260816000000_marketplace_sync_engine_and_order_lifecycle.sql

-- 1. Create Sync Jobs & Checkpoint Tracking Table
CREATE TABLE IF NOT EXISTS public.marketplace_sync_jobs (
  job_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL,
  marketplace_account_id UUID REFERENCES public.marketplace_accounts(account_id) ON DELETE CASCADE,
  marketplace TEXT NOT NULL,
  sync_type TEXT NOT NULL DEFAULT 'HISTORICAL_BACKFILL',
  tier TEXT NOT NULL DEFAULT 'STANDARD',
  date_from DATE NOT NULL,
  date_to DATE NOT NULL,
  current_chunk_start DATE,
  current_chunk_end DATE,
  total_chunks INT DEFAULT 1,
  completed_chunks INT DEFAULT 0,
  orders_synced INT DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'QUEUED',
  error_message TEXT,
  last_checkpoint_ts TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_marketplace_sync_jobs_tenant_status 
  ON public.marketplace_sync_jobs(tenant_id, status);

CREATE INDEX IF NOT EXISTS idx_marketplace_sync_jobs_account 
  ON public.marketplace_sync_jobs(marketplace_account_id);


-- 2. Dispatch Tenant Historical Sync (SaaS Tier Quota Driven: 90 vs 180 Days)
CREATE OR REPLACE FUNCTION public.dispatch_tenant_historical_sync(
  p_account_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_account RECORD;
  v_tenant_id UUID;
  v_tier TEXT := 'STANDARD';
  v_retention_days INT := 90;
  v_date_from DATE;
  v_date_to DATE := CURRENT_DATE;
  v_job_id UUID;
  v_total_chunks INT;
BEGIN
  -- Get account details
  SELECT * INTO v_account 
  FROM public.marketplace_accounts 
  WHERE account_id = p_account_id 
     OR (p_account_id IS NULL AND is_active = true)
  LIMIT 1;

  IF v_account IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Akun marketplace tidak ditemukan.');
  END IF;

  v_tenant_id := v_account.tenant_id;

  -- Check tenant subscription tier
  SELECT COALESCE(tier, 'STANDARD') INTO v_tier
  FROM public.tenant_subscriptions
  WHERE tenant_id = v_tenant_id
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_tier IS NULL THEN
    v_tier := 'STANDARD';
  END IF;

  -- Determine historical backfill window by SaaS Tier
  IF lower(v_tier) ~ 'pro|enterprise|ultimate|unlimited' THEN
    v_retention_days := 180;
  ELSE
    v_retention_days := 90;
  END IF;

  v_date_from := v_date_to - v_retention_days;
  v_total_chunks := CEIL(v_retention_days / 15.0)::INT;

  -- Check if active job already running
  SELECT job_id INTO v_job_id
  FROM public.marketplace_sync_jobs
  WHERE marketplace_account_id = v_account.account_id
    AND status IN ('QUEUED', 'RUNNING')
  LIMIT 1;

  IF v_job_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'job_id', v_job_id,
      'status', 'ALREADY_RUNNING',
      'message', format('Job sinkronisasi %s hari (%s) sudah aktif di antrian.', v_retention_days, v_tier)
    );
  END IF;

  -- Insert new sync job
  INSERT INTO public.marketplace_sync_jobs (
    tenant_id,
    marketplace_account_id,
    marketplace,
    sync_type,
    tier,
    date_from,
    date_to,
    current_chunk_start,
    current_chunk_end,
    total_chunks,
    completed_chunks,
    orders_synced,
    status
  ) VALUES (
    v_tenant_id,
    v_account.account_id,
    v_account.marketplace,
    'HISTORICAL_BACKFILL',
    v_tier,
    v_date_from,
    v_date_to,
    v_date_from,
    LEAST(v_date_from + 14, v_date_to),
    v_total_chunks,
    0,
    0,
    'QUEUED'
  )
  RETURNING job_id INTO v_job_id;

  RETURN jsonb_build_object(
    'ok', true,
    'job_id', v_job_id,
    'tier', v_tier,
    'date_from', v_date_from,
    'date_to', v_date_to,
    'total_chunks', v_total_chunks,
    'message', format('Berhasil menjadwalkan penarikan data historis %s hari (Paket: %s).', v_retention_days, v_tier)
  );
END;
$function$;


-- 3. Procedure to Reconcile & Advance Stale Historical Orders & Payouts
CREATE OR REPLACE FUNCTION public.reconcile_and_advance_stale_order_lifecycles()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_updated_status_count INT := 0;
  v_settled_payouts_count INT := 0;
  v_order_record RECORD;
  v_order_gross NUMERIC;
  v_platform_fee NUMERIC;
  v_net_payout NUMERIC;
  v_order_date DATE;
BEGIN
  -- Step 1: Advance status of orders older than 14 days that are past return window
  WITH updated_orders AS (
    UPDATE public.marketplace_orders
    SET order_status = 'COMPLETED',
        status = 'COMPLETED',
        updated_at = NOW()
    WHERE (COALESCE(order_created_at, created_time, created_at) AT TIME ZONE 'Asia/Jakarta')::DATE < CURRENT_DATE - 14
      AND LOWER(COALESCE(order_status, status, '')) ~ '(to_confirm_receive|pesanan diterima|shipped|in_transit|on_process)'
      AND NOT (LOWER(COALESCE(order_status, status, '')) ~ '(cancel|batal|return|refund|rts|dibatalkan)')
    RETURNING marketplace_order_id
  )
  SELECT count(*) INTO v_updated_status_count FROM updated_orders;

  -- Step 2: Ensure all COMPLETED / DELIVERED orders have finance settlement reports
  FOR v_order_record IN
    WITH item_sum AS (
      SELECT 
        marketplace_order_id,
        SUM(COALESCE(NULLIF(gross_amount, 0), quantity * unit_gross_amount, 0)) AS total_item_gross
      FROM public.marketplace_order_items
      GROUP BY marketplace_order_id
    )
    SELECT
      o.marketplace_order_id,
      o.marketplace_account_id,
      o.tenant_id,
      o.marketplace,
      COALESCE(o.external_order_id, o.order_sn, o.marketplace_order_id::text) AS order_key,
      (COALESCE(o.paid_at, o.order_created_at, o.created_time, o.created_at) AT TIME ZONE 'Asia/Jakarta')::DATE AS order_date,
      COALESCE(NULLIF(its.total_item_gross, 0), NULLIF(o.gross_amount, 0), o.paid_amount, o.total_amount, 0)::NUMERIC AS gross_amount
    FROM public.marketplace_orders o
    LEFT JOIN item_sum its ON its.marketplace_order_id = o.marketplace_order_id
    LEFT JOIN public.marketplace_finance_reports fr
      ON fr.tenant_id = o.tenant_id
     AND (fr.marketplace_order_id = o.marketplace_order_id OR fr.order_id = COALESCE(o.external_order_id, o.order_sn, o.marketplace_order_id::text))
    WHERE fr.finance_report_id IS NULL
      AND LOWER(COALESCE(o.order_status, o.status, '')) ~ '(completed|complete|selesai|delivered|finished)'
      AND NOT (LOWER(COALESCE(o.order_status, o.status, '')) ~ '(cancel|batal|return|refund|rts|dibatalkan)')
  LOOP
    v_order_gross := v_order_record.gross_amount;

    v_platform_fee := CASE
      WHEN LOWER(v_order_record.marketplace) ~ 'shopee' THEN ROUND(v_order_gross * 0.15, 2)
      ELSE ROUND(v_order_gross * 0.18, 2)
    END;

    v_net_payout := GREATEST(v_order_gross - v_platform_fee, 0);
    v_order_date := COALESCE(v_order_record.order_date, CURRENT_DATE);

    INSERT INTO public.marketplace_finance_reports (
      finance_report_id,
      tenant_id,
      marketplace_order_id,
      marketplace_account_id,
      marketplace,
      order_id,
      settlement_status,
      settlement_date,
      period_start,
      period_end,
      gross_amount,
      payout_amount,
      net_settlement,
      received_amount,
      platform_fee,
      total_fees,
      report_type,
      note,
      created_at,
      updated_at
    ) VALUES (
      gen_random_uuid(),
      v_order_record.tenant_id,
      v_order_record.marketplace_order_id,
      v_order_record.marketplace_account_id,
      v_order_record.marketplace,
      v_order_record.order_key,
      'SETTLED',
      v_order_date,
      v_order_date,
      v_order_date,
      v_order_gross,
      v_net_payout,
      v_net_payout,
      v_net_payout,
      v_platform_fee,
      v_platform_fee,
      'order_settlement',
      'Auto-reconciled historical settlement',
      NOW(),
      NOW()
    )
    ON CONFLICT DO NOTHING;

    v_settled_payouts_count := v_settled_payouts_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'updated_status_count', v_updated_status_count,
    'settled_payouts_count', v_settled_payouts_count,
    'message', format('Rekonsiliasi selesai: %s order lama diperbarui statusnya ke SELESAI, %s payout laporan keuangan berhasil di-generate.', v_updated_status_count, v_settled_payouts_count)
  );
END;
$function$;


-- 4. 90-Day Raw Payload Purge Procedure (Multi-Tier Data Retention)
CREATE OR REPLACE FUNCTION public.maintenance_purge_old_raw_payloads(
  p_retention_days INT DEFAULT 90
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_purged_orders INT := 0;
  v_cutoff_date DATE := CURRENT_DATE - p_retention_days;
BEGIN
  WITH purged AS (
    UPDATE public.marketplace_orders
    SET raw_order = NULL
    WHERE (COALESCE(order_created_at, created_time, created_at) AT TIME ZONE 'Asia/Jakarta')::DATE < v_cutoff_date
      AND raw_order IS NOT NULL
    RETURNING marketplace_order_id
  )
  SELECT count(*) INTO v_purged_orders FROM purged;

  RETURN jsonb_build_object(
    'ok', true,
    'cutoff_date', v_cutoff_date,
    'purged_order_payloads_count', v_purged_orders,
    'message', format('Berhasil membersihkan %s payload JSON mentah (> %s hari). Data keuangan & SKU tetap aman 100%%.', v_purged_orders, p_retention_days)
  );
END;
$function$;
