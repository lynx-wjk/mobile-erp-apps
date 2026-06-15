-- Migration: 20260615160000_phase5_subscription_core.sql
-- Goal: Create SaaS subscription core database schema and seeding data.
-- No subscription enforcement is active yet.

-- 1. Create feature_catalog
CREATE TABLE IF NOT EXISTS public.feature_catalog (
  feature_key text PRIMARY KEY,
  feature_name text NOT NULL,
  description text,
  feature_group text NOT NULL DEFAULT 'general',
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- 2. Create subscription_plans
CREATE TABLE IF NOT EXISTS public.subscription_plans (
  plan_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_code text UNIQUE NOT NULL,
  plan_name text NOT NULL,
  description text,
  billing_period text NOT NULL DEFAULT 'monthly',
  price_amount numeric(14,2) NOT NULL DEFAULT 0.00,
  currency text NOT NULL DEFAULT 'IDR',
  max_users integer,
  max_marketplace_accounts integer,
  max_shopee_accounts integer,
  max_tiktok_accounts integer,
  max_storage_mb integer,
  max_order_retention_days integer NOT NULL DEFAULT 90,
  is_trial boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- 3. Create subscription_plan_features
CREATE TABLE IF NOT EXISTS public.subscription_plan_features (
  plan_id uuid REFERENCES public.subscription_plans(plan_id) ON DELETE CASCADE,
  feature_key text REFERENCES public.feature_catalog(feature_key) ON DELETE CASCADE,
  enabled boolean NOT NULL DEFAULT true,
  limit_value integer,
  config jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (plan_id, feature_key)
);

-- 4. Create tenant_subscriptions
CREATE TABLE IF NOT EXISTS public.tenant_subscriptions (
  tenant_subscription_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.app_tenants(tenant_id) ON DELETE CASCADE,
  plan_id uuid REFERENCES public.subscription_plans(plan_id),
  status text NOT NULL DEFAULT 'trialing' CHECK (status IN ('trialing', 'active', 'past_due', 'suspended', 'canceled', 'expired')),
  started_at timestamptz NOT NULL DEFAULT now(),
  trial_ends_at timestamptz,
  current_period_start timestamptz,
  current_period_end timestamptz,
  canceled_at timestamptz,
  suspended_at timestamptz,
  grace_until timestamptz,
  external_customer_id text,
  external_subscription_id text,
  notes text,
  created_by uuid REFERENCES public.users(user_id) ON DELETE SET NULL,
  updated_by uuid REFERENCES public.users(user_id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- 5. Create tenant_subscription_overrides
CREATE TABLE IF NOT EXISTS public.tenant_subscription_overrides (
  override_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.app_tenants(tenant_id) ON DELETE CASCADE,
  feature_key text REFERENCES public.feature_catalog(feature_key) ON DELETE CASCADE,
  override_type text NOT NULL CHECK (override_type IN ('feature', 'limit', 'config')),
  enabled boolean,
  limit_value integer,
  config jsonb NOT NULL DEFAULT '{}'::jsonb,
  reason text,
  starts_at timestamptz NOT NULL DEFAULT now(),
  ends_at timestamptz,
  created_by uuid REFERENCES public.users(user_id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 6. Create tenant_subscription_events
CREATE TABLE IF NOT EXISTS public.tenant_subscription_events (
  event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.app_tenants(tenant_id) ON DELETE CASCADE,
  tenant_subscription_id uuid REFERENCES public.tenant_subscriptions(tenant_subscription_id) ON DELETE SET NULL,
  event_type text NOT NULL,
  old_status text,
  new_status text,
  old_plan_id uuid REFERENCES public.subscription_plans(plan_id) ON DELETE SET NULL,
  new_plan_id uuid REFERENCES public.subscription_plans(plan_id) ON DELETE SET NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by uuid REFERENCES public.users(user_id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 7. Create tenant_deletion_audit (Unlinked via foreign key to prevent audit record drops on tenant purge)
CREATE TABLE IF NOT EXISTS public.tenant_deletion_audit (
  deletion_audit_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  requested_by uuid REFERENCES public.users(user_id) ON DELETE SET NULL,
  approved_by uuid REFERENCES public.users(user_id) ON DELETE SET NULL,
  deletion_type text NOT NULL DEFAULT 'manual',
  verification_text text,
  status text NOT NULL DEFAULT 'requested',
  summary jsonb NOT NULL DEFAULT '{}'::jsonb,
  requested_at timestamptz NOT NULL DEFAULT now(),
  approved_at timestamptz,
  executed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 8. Create Indexes
CREATE INDEX IF NOT EXISTS idx_feature_catalog_active_sort ON public.feature_catalog(is_active, sort_order);
CREATE INDEX IF NOT EXISTS idx_subscription_plans_plan_code ON public.subscription_plans(plan_code);
CREATE INDEX IF NOT EXISTS idx_subscription_plans_active_sort ON public.subscription_plans(is_active, sort_order);
CREATE INDEX IF NOT EXISTS idx_subscription_plan_features_key ON public.subscription_plan_features(feature_key);
CREATE INDEX IF NOT EXISTS idx_tenant_subscriptions_tenant_id ON public.tenant_subscriptions(tenant_id);
CREATE INDEX IF NOT EXISTS idx_tenant_subscriptions_status ON public.tenant_subscriptions(status);
CREATE INDEX IF NOT EXISTS idx_tenant_subscriptions_period_end ON public.tenant_subscriptions(current_period_end);
CREATE INDEX IF NOT EXISTS idx_tenant_subscription_overrides_tenant_id ON public.tenant_subscription_overrides(tenant_id);
CREATE INDEX IF NOT EXISTS idx_tenant_subscription_overrides_feature_key ON public.tenant_subscription_overrides(feature_key);
CREATE INDEX IF NOT EXISTS idx_tenant_subscription_events_tenant_id ON public.tenant_subscription_events(tenant_id);
CREATE INDEX IF NOT EXISTS idx_tenant_deletion_audit_tenant_id ON public.tenant_deletion_audit(tenant_id);

-- 9. Setup Triggers for updated_at
CREATE TRIGGER touch_feature_catalog_updated_at
  BEFORE UPDATE ON public.feature_catalog
  FOR EACH ROW
  EXECUTE FUNCTION public.app_touch_updated_at();

CREATE TRIGGER touch_subscription_plans_updated_at
  BEFORE UPDATE ON public.subscription_plans
  FOR EACH ROW
  EXECUTE FUNCTION public.app_touch_updated_at();

CREATE TRIGGER touch_tenant_subscriptions_updated_at
  BEFORE UPDATE ON public.tenant_subscriptions
  FOR EACH ROW
  EXECUTE FUNCTION public.app_touch_updated_at();

-- 10. Enable Row Level Security (RLS)
ALTER TABLE public.feature_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscription_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscription_plan_features ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenant_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenant_subscription_overrides ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenant_subscription_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenant_deletion_audit ENABLE ROW LEVEL SECURITY;

-- 11. Define RLS Policies

-- Master tables read policies: allow SELECT for all authenticated users
CREATE POLICY feature_catalog_select ON public.feature_catalog
  FOR SELECT TO authenticated USING (true);

CREATE POLICY subscription_plans_select ON public.subscription_plans
  FOR SELECT TO authenticated USING (true);

CREATE POLICY subscription_plan_features_select ON public.subscription_plan_features
  FOR SELECT TO authenticated USING (true);

-- Master tables write policies: restrict to platform_owner only
CREATE POLICY feature_catalog_owner_all ON public.feature_catalog
  FOR ALL TO authenticated
  USING (
    exists (
      select 1 from public.users u
      where u.user_id = auth.uid()
        and u.role_id = 'platform_owner'
        and coalesce(u.status, 'active') = 'active'
    )
  )
  WITH CHECK (
    exists (
      select 1 from public.users u
      where u.user_id = auth.uid()
        and u.role_id = 'platform_owner'
        and coalesce(u.status, 'active') = 'active'
    )
  );

CREATE POLICY subscription_plans_owner_all ON public.subscription_plans
  FOR ALL TO authenticated
  USING (
    exists (
      select 1 from public.users u
      where u.user_id = auth.uid()
        and u.role_id = 'platform_owner'
        and coalesce(u.status, 'active') = 'active'
    )
  )
  WITH CHECK (
    exists (
      select 1 from public.users u
      where u.user_id = auth.uid()
        and u.role_id = 'platform_owner'
        and coalesce(u.status, 'active') = 'active'
    )
  );

CREATE POLICY subscription_plan_features_owner_all ON public.subscription_plan_features
  FOR ALL TO authenticated
  USING (
    exists (
      select 1 from public.users u
      where u.user_id = auth.uid()
        and u.role_id = 'platform_owner'
        and coalesce(u.status, 'active') = 'active'
    )
  )
  WITH CHECK (
    exists (
      select 1 from public.users u
      where u.user_id = auth.uid()
        and u.role_id = 'platform_owner'
        and coalesce(u.status, 'active') = 'active'
    )
  );

-- Tenant subscription tables SELECT policies: scope to own tenant using the existing helper
CREATE POLICY tenant_subscriptions_tenant_select ON public.tenant_subscriptions
  FOR SELECT TO authenticated USING (public.app_has_tenant_access(tenant_id));

CREATE POLICY tenant_subscription_overrides_tenant_select ON public.tenant_subscription_overrides
  FOR SELECT TO authenticated USING (public.app_has_tenant_access(tenant_id));

CREATE POLICY tenant_subscription_events_tenant_select ON public.tenant_subscription_events
  FOR SELECT TO authenticated USING (public.app_has_tenant_access(tenant_id));

-- Tenant subscription tables write policies: restrict to platform_owner only
CREATE POLICY tenant_subscriptions_owner_all ON public.tenant_subscriptions
  FOR ALL TO authenticated
  USING (
    exists (
      select 1 from public.users u
      where u.user_id = auth.uid()
        and u.role_id = 'platform_owner'
        and coalesce(u.status, 'active') = 'active'
    )
  )
  WITH CHECK (
    exists (
      select 1 from public.users u
      where u.user_id = auth.uid()
        and u.role_id = 'platform_owner'
        and coalesce(u.status, 'active') = 'active'
    )
  );

CREATE POLICY tenant_subscription_overrides_owner_all ON public.tenant_subscription_overrides
  FOR ALL TO authenticated
  USING (
    exists (
      select 1 from public.users u
      where u.user_id = auth.uid()
        and u.role_id = 'platform_owner'
        and coalesce(u.status, 'active') = 'active'
    )
  )
  WITH CHECK (
    exists (
      select 1 from public.users u
      where u.user_id = auth.uid()
        and u.role_id = 'platform_owner'
        and coalesce(u.status, 'active') = 'active'
    )
  );

CREATE POLICY tenant_subscription_events_owner_all ON public.tenant_subscription_events
  FOR ALL TO authenticated
  USING (
    exists (
      select 1 from public.users u
      where u.user_id = auth.uid()
        and u.role_id = 'platform_owner'
        and coalesce(u.status, 'active') = 'active'
    )
  )
  WITH CHECK (
    exists (
      select 1 from public.users u
      where u.user_id = auth.uid()
        and u.role_id = 'platform_owner'
        and coalesce(u.status, 'active') = 'active'
    )
  );

-- Tenant deletion audit: completely restricted to platform owners
CREATE POLICY tenant_deletion_audit_owner_all ON public.tenant_deletion_audit
  FOR ALL TO authenticated
  USING (
    exists (
      select 1 from public.users u
      where u.user_id = auth.uid()
        and u.role_id = 'platform_owner'
        and coalesce(u.status, 'active') = 'active'
    )
  )
  WITH CHECK (
    exists (
      select 1 from public.users u
      where u.user_id = auth.uid()
        and u.role_id = 'platform_owner'
        and coalesce(u.status, 'active') = 'active'
    )
  );

-- 12. Seeding feature_catalog
INSERT INTO public.feature_catalog (feature_key, feature_name, description, feature_group, is_active, sort_order)
VALUES
  ('platform_owner_dashboard', 'Platform Owner Dashboard', 'Full administrative panel for platform owners', 'admin', true, 10),
  ('tenant_management', 'Tenant Management', 'View, edit, suspend or purge tenants', 'admin', true, 20),
  ('invite_management', 'Invite Management', 'Manage tenant invitation and platform registration tokens', 'admin', true, 30),
  ('stock_basic', 'Basic Stock Control', 'Stock-in, stock-out and simple transaction history', 'stock', true, 40),
  ('production_basic', 'Basic Production Management', 'Production batch tracking and step operations', 'production', true, 50),
  ('finance_basic', 'Basic Finance Ledger', 'Canonical income/expense logs and balance reports', 'finance', true, 60),
  ('marketplace_accounts', 'Marketplace Account Connections', 'Link third-party platforms (Shopee, TikTok Shop)', 'marketplace', true, 70),
  ('marketplace_order_sync', 'Order Synchronization', 'Synchronize customer orders and statuses', 'marketplace', true, 80),
  ('marketplace_product_sync', 'Product Catalog Sync', 'Map and synchronize store items', 'marketplace', true, 90),
  ('marketplace_stock_sync', 'Automatic Stock Syncing', 'Real-time stock adjustment on channels', 'marketplace', true, 100),
  ('marketplace_finance_sync', 'Finance Settlement Syncing', 'Sync payouts, margins and escrow reports', 'marketplace', true, 110),
  ('marketplace_return_refund', 'Return & Refund Management', 'Sync customer returns and compute return costs', 'marketplace', true, 120),
  ('marketplace_job_monitor', 'Job Queue Monitor', 'Real-time monitoring of sync workers and backlogs', 'marketplace', true, 130),
  ('attendance_basic', 'Basic Attendance', 'HR employee check-in and check-out logs', 'hr', true, 140),
  ('task_basic', 'Basic Task Tracking', 'Assign tasks to workers and track completion states', 'general', true, 150),
  ('live_schedule_basic', 'Basic Live Schedule', 'Host live stream planning and schedules', 'general', true, 160),
  ('content_task_basic', 'Content Tasks', 'Planning, content creation workflow and proof checks', 'general', true, 170),
  ('purchase_requests', 'Purchase Requests', 'Procurement request forms and approval flow', 'finance', true, 180),
  ('finance_expenses', 'Detailed Operational Expenses', 'Separate, itemized operational and production expenses', 'finance', true, 190),
  ('finance_abnormal_monitor', 'Finance Abnormal Monitor', 'Audit and highlight anomalies in payout vs expected income', 'finance', true, 200),
  ('subscription_management', 'Subscription & Billing Management', 'Self-service plan upgrades and subscription status', 'admin', true, 210)
ON CONFLICT (feature_key) DO UPDATE
SET feature_name = EXCLUDED.feature_name,
    description = EXCLUDED.description,
    feature_group = EXCLUDED.feature_group,
    is_active = EXCLUDED.is_active,
    sort_order = EXCLUDED.sort_order;

-- 13. Seeding subscription_plans
INSERT INTO public.subscription_plans (plan_code, plan_name, description, billing_period, price_amount, currency, max_users, max_marketplace_accounts, max_shopee_accounts, max_tiktok_accounts, max_storage_mb, max_order_retention_days, is_trial, is_active, sort_order)
VALUES
  ('trial', 'Trial Plan', 'Free trial for new tenants', 'monthly', 0.00, 'IDR', 5, 2, 1, 1, 100, 90, true, true, 1),
  ('starter', 'Starter Plan', 'Basic plan for small teams', 'monthly', 150000.00, 'IDR', 10, 5, 2, 2, 500, 90, false, true, 2),
  ('growth', 'Growth Plan', 'Plan for growing businesses', 'monthly', 300000.00, 'IDR', 25, 10, 5, 5, 2048, 180, false, true, 3),
  ('pro', 'Pro Plan', 'Professional plan with advanced features', 'monthly', 600000.00, 'IDR', 100, 25, 12, 12, 10240, 365, false, true, 4),
  ('enterprise', 'Enterprise Plan', 'Enterprise plan with unlimited features', 'monthly', 1500000.00, 'IDR', NULL, NULL, NULL, NULL, NULL, 365, false, true, 5)
ON CONFLICT (plan_code) DO UPDATE
SET plan_name = EXCLUDED.plan_name,
    description = EXCLUDED.description,
    billing_period = EXCLUDED.billing_period,
    price_amount = EXCLUDED.price_amount,
    currency = EXCLUDED.currency,
    max_users = EXCLUDED.max_users,
    max_marketplace_accounts = EXCLUDED.max_marketplace_accounts,
    max_shopee_accounts = EXCLUDED.max_shopee_accounts,
    max_tiktok_accounts = EXCLUDED.max_tiktok_accounts,
    max_storage_mb = EXCLUDED.max_storage_mb,
    max_order_retention_days = EXCLUDED.max_order_retention_days,
    is_trial = EXCLUDED.is_trial,
    is_active = EXCLUDED.is_active,
    sort_order = EXCLUDED.sort_order;

-- 14. Seeding subscription_plan_features (many-to-many relationship)

-- trial: stock_basic, production_basic, finance_basic, invite_management
WITH plans AS (
  SELECT plan_id, plan_code FROM public.subscription_plans
)
INSERT INTO public.subscription_plan_features (plan_id, feature_key, enabled, limit_value, config)
SELECT p.plan_id, f.feature_key, true, NULL::integer, '{}'::jsonb
FROM plans p
CROSS JOIN (
  SELECT 'stock_basic' AS feature_key UNION ALL
  SELECT 'production_basic' UNION ALL
  SELECT 'finance_basic' UNION ALL
  SELECT 'invite_management'
) f
WHERE p.plan_code = 'trial'
ON CONFLICT (plan_id, feature_key) DO UPDATE
SET
  enabled = EXCLUDED.enabled,
  limit_value = EXCLUDED.limit_value,
  config = EXCLUDED.config;

-- starter: trial features + marketplace_accounts + marketplace_order_sync + marketplace_product_sync
WITH plans AS (
  SELECT plan_id, plan_code FROM public.subscription_plans
)
INSERT INTO public.subscription_plan_features (plan_id, feature_key, enabled, limit_value, config)
SELECT p.plan_id, f.feature_key, true, NULL::integer, '{}'::jsonb
FROM plans p
CROSS JOIN (
  SELECT 'stock_basic' AS feature_key UNION ALL
  SELECT 'production_basic' UNION ALL
  SELECT 'finance_basic' UNION ALL
  SELECT 'invite_management' UNION ALL
  SELECT 'marketplace_accounts' UNION ALL
  SELECT 'marketplace_order_sync' UNION ALL
  SELECT 'marketplace_product_sync'
) f
WHERE p.plan_code = 'starter'
ON CONFLICT (plan_id, feature_key) DO UPDATE
SET
  enabled = EXCLUDED.enabled,
  limit_value = EXCLUDED.limit_value,
  config = EXCLUDED.config;

-- growth: starter + marketplace_stock_sync + marketplace_finance_sync + marketplace_job_monitor + finance_expenses
WITH plans AS (
  SELECT plan_id, plan_code FROM public.subscription_plans
)
INSERT INTO public.subscription_plan_features (plan_id, feature_key, enabled, limit_value, config)
SELECT p.plan_id, f.feature_key, true, NULL::integer, '{}'::jsonb
FROM plans p
CROSS JOIN (
  SELECT 'stock_basic' AS feature_key UNION ALL
  SELECT 'production_basic' UNION ALL
  SELECT 'finance_basic' UNION ALL
  SELECT 'invite_management' UNION ALL
  SELECT 'marketplace_accounts' UNION ALL
  SELECT 'marketplace_order_sync' UNION ALL
  SELECT 'marketplace_product_sync' UNION ALL
  SELECT 'marketplace_stock_sync' UNION ALL
  SELECT 'marketplace_finance_sync' UNION ALL
  SELECT 'marketplace_job_monitor' UNION ALL
  SELECT 'finance_expenses'
) f
WHERE p.plan_code = 'growth'
ON CONFLICT (plan_id, feature_key) DO UPDATE
SET
  enabled = EXCLUDED.enabled,
  limit_value = EXCLUDED.limit_value,
  config = EXCLUDED.config;

-- pro: growth + marketplace_return_refund + finance_abnormal_monitor + attendance_basic + task_basic + live_schedule_basic + content_task_basic + purchase_requests
WITH plans AS (
  SELECT plan_id, plan_code FROM public.subscription_plans
)
INSERT INTO public.subscription_plan_features (plan_id, feature_key, enabled, limit_value, config)
SELECT p.plan_id, f.feature_key, true, NULL::integer, '{}'::jsonb
FROM plans p
CROSS JOIN (
  SELECT 'stock_basic' AS feature_key UNION ALL
  SELECT 'production_basic' UNION ALL
  SELECT 'finance_basic' UNION ALL
  SELECT 'invite_management' UNION ALL
  SELECT 'marketplace_accounts' UNION ALL
  SELECT 'marketplace_order_sync' UNION ALL
  SELECT 'marketplace_product_sync' UNION ALL
  SELECT 'marketplace_stock_sync' UNION ALL
  SELECT 'marketplace_finance_sync' UNION ALL
  SELECT 'marketplace_job_monitor' UNION ALL
  SELECT 'finance_expenses' UNION ALL
  SELECT 'marketplace_return_refund' UNION ALL
  SELECT 'finance_abnormal_monitor' UNION ALL
  SELECT 'attendance_basic' UNION ALL
  SELECT 'task_basic' UNION ALL
  SELECT 'live_schedule_basic' UNION ALL
  SELECT 'content_task_basic' UNION ALL
  SELECT 'purchase_requests'
) f
WHERE p.plan_code = 'pro'
ON CONFLICT (plan_id, feature_key) DO UPDATE
SET
  enabled = EXCLUDED.enabled,
  limit_value = EXCLUDED.limit_value,
  config = EXCLUDED.config;

-- enterprise: all active features
WITH plans AS (
  SELECT plan_id, plan_code FROM public.subscription_plans
)
INSERT INTO public.subscription_plan_features (plan_id, feature_key, enabled, limit_value, config)
SELECT p.plan_id, f.feature_key, true, NULL::integer, '{}'::jsonb
FROM plans p
CROSS JOIN public.feature_catalog f
WHERE p.plan_code = 'enterprise'
  AND f.is_active = true
ON CONFLICT (plan_id, feature_key) DO UPDATE
SET
  enabled = EXCLUDED.enabled,
  limit_value = EXCLUDED.limit_value,
  config = EXCLUDED.config;

-- 15. Create Optional Read-Only RPCs (unversioned, SECURITY DEFINER, return JSONB)

CREATE OR REPLACE FUNCTION public.list_subscription_plans_for_app()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_plans jsonb;
begin
  select jsonb_agg(
    jsonb_build_object(
      'plan_id', sp.plan_id,
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
      'features', (
        select jsonb_agg(spf.feature_key)
        from public.subscription_plan_features spf
        where spf.plan_id = sp.plan_id
          and spf.enabled = true
      )
    )
  ) into v_plans
  from public.subscription_plans sp
  where sp.is_active = true
  order by sp.sort_order;

  return jsonb_build_object(
    'ok', true,
    'plans', coalesce(v_plans, '[]'::jsonb)
  );
end;
$$;

ALTER FUNCTION public.list_subscription_plans_for_app() OWNER TO postgres;

CREATE OR REPLACE FUNCTION public.get_my_subscription_snapshot()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_user_id uuid;
  v_tenant_id uuid;
  v_is_platform_owner boolean;
  v_sub_row record;
  v_features jsonb;
  v_overrides jsonb;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    return jsonb_build_object(
      'ok', false,
      'error', 'unauthenticated'
    );
  end if;

  -- Get user info
  select tenant_id, (role_id = 'platform_owner')
  into v_tenant_id, v_is_platform_owner
  from public.users
  where user_id = v_user_id
    and coalesce(status, 'active') = 'active';

  -- Platform owners bypass tenant checks and get a full snapshot
  if v_tenant_id is null and v_is_platform_owner then
    select jsonb_agg(feature_key) into v_features
    from public.feature_catalog
    where is_active = true;

    return jsonb_build_object(
      'ok', true,
      'status', 'active',
      'plan_code', 'platform_owner',
      'plan_name', 'Platform Owner',
      'features', coalesce(v_features, '[]'::jsonb),
      'max_users', null,
      'max_marketplace_accounts', null,
      'max_shopee_accounts', null,
      'max_tiktok_accounts', null,
      'max_storage_mb', null,
      'max_order_retention_days', 365,
      'is_trial', false
    );
  end if;

  if v_tenant_id is null then
    return jsonb_build_object(
      'ok', false,
      'error', 'no_tenant_assigned'
    );
  end if;

  -- Fetch current subscription
  select ts.*, sp.plan_code, sp.plan_name, sp.max_users, sp.max_marketplace_accounts,
         sp.max_shopee_accounts, sp.max_tiktok_accounts, sp.max_storage_mb, sp.max_order_retention_days, sp.is_trial
  into v_sub_row
  from public.tenant_subscriptions ts
  join public.subscription_plans sp on ts.plan_id = sp.plan_id
  where ts.tenant_id = v_tenant_id
  order by ts.created_at desc
  limit 1;

  -- Safe fallback if no subscription assigned
  if v_sub_row.tenant_subscription_id is null then
    return jsonb_build_object(
      'ok', true,
      'status', 'unassigned',
      'plan_code', 'unassigned',
      'plan_name', 'Unassigned (Fallback)',
      'features', jsonb_build_array('stock_basic', 'production_basic', 'finance_basic', 'invite_management'),
      'max_users', 5,
      'max_marketplace_accounts', 0,
      'max_shopee_accounts', 0,
      'max_tiktok_accounts', 0,
      'max_storage_mb', 100,
      'max_order_retention_days', 90,
      'is_trial', false
    );
  end if;

  -- Fetch plan features
  select jsonb_agg(feature_key) into v_features
  from public.subscription_plan_features
  where plan_id = v_sub_row.plan_id
    and enabled = true;

  -- Fetch overrides
  select jsonb_object_agg(feature_key, jsonb_build_object('enabled', enabled, 'limit_value', limit_value, 'config', config))
  into v_overrides
  from public.tenant_subscription_overrides
  where tenant_id = v_tenant_id
    and starts_at <= now()
    and (ends_at is null or ends_at >= now());

  return jsonb_build_object(
    'ok', true,
    'status', v_sub_row.status,
    'plan_code', v_sub_row.plan_code,
    'plan_name', v_sub_row.plan_name,
    'features', coalesce(v_features, '[]'::jsonb),
    'overrides', coalesce(v_overrides, '{}'::jsonb),
    'max_users', v_sub_row.max_users,
    'max_marketplace_accounts', v_sub_row.max_marketplace_accounts,
    'max_shopee_accounts', v_sub_row.max_shopee_accounts,
    'max_tiktok_accounts', v_sub_row.max_tiktok_accounts,
    'max_storage_mb', v_sub_row.max_storage_mb,
    'max_order_retention_days', v_sub_row.max_order_retention_days,
    'is_trial', v_sub_row.is_trial
  );
end;
$$;

ALTER FUNCTION public.get_my_subscription_snapshot() OWNER TO postgres;
