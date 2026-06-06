-- DRAFT ONLY. Apply to the mobile_erp clone project, not the current production
-- project, after confirming the payment gateway flow.
-- Purpose: baseline QRIS subscription payment tables.

create table if not exists public.subscription_invoices (
  subscription_invoice_id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  plan_id text not null references public.subscription_plans(plan_id),
  amount numeric not null default 0,
  currency text not null default 'IDR',
  period_start date not null,
  period_end date not null,
  status text not null default 'pending',
  gateway text not null default 'midtrans',
  gateway_order_id text,
  qr_string text,
  qr_image_url text,
  gateway_payload jsonb not null default '{}'::jsonb,
  paid_at timestamptz,
  expires_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (gateway, gateway_order_id)
);

create table if not exists public.subscription_payments (
  subscription_payment_id uuid primary key default gen_random_uuid(),
  subscription_invoice_id uuid not null references public.subscription_invoices(subscription_invoice_id) on delete cascade,
  tenant_id uuid not null,
  plan_id text not null references public.subscription_plans(plan_id),
  gateway text not null,
  gateway_order_id text not null,
  gateway_transaction_id text,
  amount numeric not null default 0,
  currency text not null default 'IDR',
  status text not null default 'pending',
  payment_type text,
  paid_at timestamptz,
  raw_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (gateway, gateway_transaction_id)
);

create table if not exists public.payment_webhook_events (
  payment_webhook_event_id uuid primary key default gen_random_uuid(),
  gateway text not null,
  event_id text,
  gateway_order_id text,
  signature_valid boolean not null default false,
  processed boolean not null default false,
  error_message text,
  payload jsonb not null default '{}'::jsonb,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  unique (gateway, event_id)
);

alter table public.subscription_invoices enable row level security;
alter table public.subscription_payments enable row level security;
alter table public.payment_webhook_events enable row level security;

create index if not exists subscription_invoices_tenant_status_idx
  on public.subscription_invoices(tenant_id, status, period_end);

create index if not exists subscription_payments_tenant_status_idx
  on public.subscription_payments(tenant_id, status, paid_at);

create index if not exists payment_webhook_events_gateway_order_idx
  on public.payment_webhook_events(gateway, gateway_order_id);
