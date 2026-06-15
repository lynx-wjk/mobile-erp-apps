# Phase 5 Safe Analysis: SaaS Subscription Core

This document outlines the database schema design and integration strategy for the SaaS Subscription Core. It does not introduce payment gateway integrations; plans are manually controlled and configured by the Platform Owner.

---

## 1. Schema Tables Design

### `feature_catalog`
Stores the list of operational features that can be restricted/licensed.
```sql
CREATE TABLE public.feature_catalog (
    feature_id text PRIMARY KEY,
    name text NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now()
);
```

### `subscription_plans`
Stores predefined plan structures (e.g. Free, Bronze, Silver, Gold).
```sql
CREATE TABLE public.subscription_plans (
    plan_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code text UNIQUE NOT NULL,
    name text NOT NULL,
    description text,
    price numeric(12,2) DEFAULT 0.00 NOT NULL,
    billing_cycle text DEFAULT 'monthly' NOT NULL, -- monthly, yearly, custom
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);
```

### `subscription_plan_features`
Maps subscription plans to enabled features in the catalog.
```sql
CREATE TABLE public.subscription_plan_features (
    plan_id uuid REFERENCES public.subscription_plans(plan_id) ON DELETE CASCADE,
    feature_id text REFERENCES public.feature_catalog(feature_id) ON DELETE CASCADE,
    is_enabled boolean DEFAULT true NOT NULL,
    limit_value jsonb DEFAULT null, -- e.g. {"max_marketplace_accounts": 3}
    PRIMARY KEY (plan_id, feature_id)
);
```

### `tenant_subscriptions`
Maps tenants to their current subscription plan.
```sql
CREATE TABLE public.tenant_subscriptions (
    subscription_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL, -- Maps to tenant system
    plan_id uuid REFERENCES public.subscription_plans(plan_id),
    status text DEFAULT 'trialing' NOT NULL, -- trialing, active, past_due, suspended, deleted
    starts_at timestamp with time zone NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    bypass_billing boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);
CREATE UNIQUE INDEX idx_tenant_active_subscription ON public.tenant_subscriptions(tenant_id) WHERE (status != 'deleted');
```

### `tenant_feature_overrides`
Allows the Platform Owner to override feature entitlements for a specific tenant.
```sql
CREATE TABLE public.tenant_feature_overrides (
    tenant_id uuid NOT NULL,
    feature_id text REFERENCES public.feature_catalog(feature_id) ON DELETE CASCADE,
    is_enabled boolean DEFAULT true NOT NULL,
    limit_value jsonb DEFAULT null,
    created_at timestamp with time zone DEFAULT now(),
    PRIMARY KEY (tenant_id, feature_id)
);
```

### `subscription_events`
Audit log of all subscription events (e.g. plan changes, state transitions).
```sql
CREATE TABLE public.subscription_events (
    event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    event_type text NOT NULL, -- plan_upgrade, billing_failed, suspended
    metadata jsonb,
    created_at timestamp with time zone DEFAULT now()
);
```

### `tenant_deletion_audit`
Immutable record of deleted tenants.
```sql
CREATE TABLE public.tenant_deletion_audit (
    audit_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    tenant_name text NOT NULL,
    deleted_at timestamp with time zone DEFAULT now(),
    deleted_by uuid NOT NULL,
    metadata jsonb
);
```

---

## 2. RLS Strategy

- **Feature Catalog, Plans & plan features**: Read-only to all authenticated users. Writes restricted to Platform Owner (`role = 'platform_owner'`).
- **Tenant Subscriptions & overrides**: Read-only to tenant users. Writes restricted to Platform Owner.
- **Subscription Events**: Write-only/append-only by system triggers. Read by Platform Owner.

---

## 3. Seed Data (Draft)

```sql
INSERT INTO public.feature_catalog (feature_id, name, description) VALUES
('marketplace_sync', 'Marketplace Sync', 'Integrate and sync orders from Shopee and TikTok Shop'),
('finance_reports', 'Finance Reports & HPP', 'Advanced HPP calculations and unpaid order monitors'),
('custom_stages', 'Custom Stages', 'Configure and persist tailor production checklist stages');

INSERT INTO public.subscription_plans (code, name, price, billing_cycle) VALUES
('free_tier', 'Free Tier Starter', 0.00, 'monthly'),
('silver_tier', 'Silver Growth Plan', 150000.00, 'monthly'),
('gold_tier', 'Gold Pro Plan', 500000.00, 'monthly');
```
