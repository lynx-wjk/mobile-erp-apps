-- DRAFT ONLY. Do not apply directly to production.
-- Purpose: additive baseline for tenant subscription entitlements.
-- This file does not drop tables and does not delete business data.

create table if not exists public.subscription_plans (
  plan_id text primary key,
  label text not null,
  max_users integer not null default 0,
  max_marketplace_accounts integer not null default 0,
  max_skus integer not null default 0,
  monthly_order_sync_limit integer not null default 0,
  features jsonb not null default '{}'::jsonb,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.tenant_subscriptions (
  tenant_id uuid primary key,
  plan_id text not null references public.subscription_plans(plan_id),
  status text not null default 'active',
  current_period_start date,
  current_period_end date,
  overrides jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.feature_entitlements (
  feature_entitlement_id uuid primary key default gen_random_uuid(),
  plan_id text not null references public.subscription_plans(plan_id),
  feature_key text not null,
  enabled boolean not null default true,
  limit_value integer,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (plan_id, feature_key)
);

create table if not exists public.usage_counters (
  usage_counter_id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  counter_key text not null,
  period_start date not null,
  period_end date not null,
  used_count integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, counter_key, period_start, period_end)
);

insert into public.subscription_plans (
  plan_id,
  label,
  max_users,
  max_marketplace_accounts,
  max_skus,
  monthly_order_sync_limit,
  features
)
values
  (
    'wms',
    'WMS Only',
    5,
    0,
    3000,
    0,
    '{"core_stock": true, "warehouse": true, "barcode_stock_in": true, "barcode_stock_out": true, "stock_history": true, "low_stock": true, "supplier_basic": true}'::jsonb
  ),
  (
    'finance',
    'Finance Only',
    8,
    0,
    0,
    0,
    '{"finance_report": true, "finance_expense": true, "finance_export": true, "purchase_verification": true, "analytics_finance": true}'::jsonb
  ),
  (
    'full',
    'Full ERP',
    250,
    50,
    100000,
    500000,
    '{"core_stock": true, "warehouse": true, "barcode_stock_in": true, "barcode_stock_out": true, "stock_history": true, "low_stock": true, "supplier_basic": true, "marketplace_accounts": true, "marketplace_order_pull": true, "marketplace_stock_sync": true, "marketplace_refund_cancel": true, "sku_mapping": true, "production": true, "purchase_material": true, "finance_report": true, "finance_expense": true, "finance_export": true, "auto_finance": true, "auto_order_pull": true, "job_monitor": true, "analytics": true, "export_import": true, "audit_center": true, "super_settings": true}'::jsonb
  )
on conflict (plan_id) do update
set
  label = excluded.label,
  max_users = excluded.max_users,
  max_marketplace_accounts = excluded.max_marketplace_accounts,
  max_skus = excluded.max_skus,
  monthly_order_sync_limit = excluded.monthly_order_sync_limit,
  features = excluded.features,
  updated_at = now();

alter table public.subscription_plans enable row level security;
alter table public.tenant_subscriptions enable row level security;
alter table public.feature_entitlements enable row level security;
alter table public.usage_counters enable row level security;

create index if not exists tenant_subscriptions_plan_idx
  on public.tenant_subscriptions(plan_id);

create index if not exists feature_entitlements_plan_feature_idx
  on public.feature_entitlements(plan_id, feature_key);

create index if not exists usage_counters_tenant_key_period_idx
  on public.usage_counters(tenant_id, counter_key, period_start, period_end);

-- Policy creation is intentionally left to the implementation migration after
-- confirming the final tenant/profile source of truth in the active database.
