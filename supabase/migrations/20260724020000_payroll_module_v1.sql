-- Migration: Payroll & Salary Slip Module v1
-- Description: Adds payroll_company_settings, user_payroll_profiles, payroll_invoices tables, storage bucket, and 90-day retention cleanup.

-- 1. Company Settings for Payroll (Logo, Address, Signatory)
CREATE TABLE IF NOT EXISTS public.payroll_company_settings (
    setting_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES public.app_tenants(tenant_id) ON DELETE RESTRICT,
    company_name TEXT NOT NULL DEFAULT 'HAI INVENTORY & APPAREL',
    company_address TEXT DEFAULT 'Jl. Raya Industri No. 88, Jakarta Barat',
    company_phone TEXT DEFAULT '+62 812-9988-7766',
    company_email TEXT DEFAULT 'finance@mdhproduction.com',
    logo_url TEXT DEFAULT '',
    signatory_name TEXT DEFAULT 'Finance Manager',
    signatory_title TEXT DEFAULT 'Manager Keuangan & HR',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_payroll_company_settings_tenant UNIQUE (tenant_id)
);

-- 2. User Payroll Profiles (Auto-saved Bank & Base Salary Presets for future reuse)
CREATE TABLE IF NOT EXISTS public.user_payroll_profiles (
    profile_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES public.app_tenants(tenant_id) ON DELETE RESTRICT,
    user_id UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
    nik TEXT DEFAULT '',
    bank_name TEXT DEFAULT 'BCA',
    bank_account_number TEXT DEFAULT '',
    bank_account_holder TEXT DEFAULT '',
    base_salary NUMERIC(14,2) NOT NULL DEFAULT 0,
    allowance_position NUMERIC(14,2) NOT NULL DEFAULT 0,
    allowance_meal_transport NUMERIC(14,2) NOT NULL DEFAULT 0,
    notes TEXT DEFAULT '',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_user_payroll_profiles_user UNIQUE (tenant_id, user_id)
);

-- 3. Payroll Invoices Table
CREATE TABLE IF NOT EXISTS public.payroll_invoices (
    invoice_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES public.app_tenants(tenant_id) ON DELETE RESTRICT,
    invoice_number TEXT NOT NULL,
    user_id UUID NOT NULL REFERENCES public.users(user_id) ON DELETE RESTRICT,
    employee_name TEXT NOT NULL,
    employee_role TEXT DEFAULT '',
    employee_nik TEXT DEFAULT '',
    period_month INT NOT NULL,
    period_year INT NOT NULL,
    period_label TEXT NOT NULL,
    bank_name TEXT DEFAULT '',
    bank_account_number TEXT DEFAULT '',
    bank_account_holder TEXT DEFAULT '',
    earnings_json JSONB NOT NULL DEFAULT '[]'::jsonb,
    deductions_json JSONB NOT NULL DEFAULT '[]'::jsonb,
    total_earnings NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_deductions NUMERIC(14,2) NOT NULL DEFAULT 0,
    net_salary NUMERIC(14,2) NOT NULL DEFAULT 0,
    pdf_storage_path TEXT DEFAULT '',
    pdf_url TEXT DEFAULT '',
    status TEXT NOT NULL DEFAULT 'generated',
    created_by UUID REFERENCES public.users(user_id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_payroll_invoices_number UNIQUE (tenant_id, invoice_number)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_payroll_company_settings_tenant ON public.payroll_company_settings(tenant_id);
CREATE INDEX IF NOT EXISTS idx_user_payroll_profiles_user ON public.user_payroll_profiles(tenant_id, user_id);
CREATE INDEX IF NOT EXISTS idx_payroll_invoices_tenant ON public.payroll_invoices(tenant_id);
CREATE INDEX IF NOT EXISTS idx_payroll_invoices_user ON public.payroll_invoices(tenant_id, user_id);
CREATE INDEX IF NOT EXISTS idx_payroll_invoices_created ON public.payroll_invoices(created_at DESC);

-- RLS Policies
ALTER TABLE public.payroll_company_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_payroll_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payroll_invoices ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_select ON public.payroll_company_settings FOR SELECT TO authenticated USING (app_has_tenant_access(tenant_id));
CREATE POLICY tenant_write ON public.payroll_company_settings FOR ALL TO authenticated USING (app_has_tenant_write_access(tenant_id)) WITH CHECK (app_has_tenant_write_access(tenant_id));

CREATE POLICY tenant_select ON public.user_payroll_profiles FOR SELECT TO authenticated USING (app_has_tenant_access(tenant_id));
CREATE POLICY tenant_write ON public.user_payroll_profiles FOR ALL TO authenticated USING (app_has_tenant_write_access(tenant_id)) WITH CHECK (app_has_tenant_write_access(tenant_id));

CREATE POLICY tenant_select ON public.payroll_invoices FOR SELECT TO authenticated USING (app_has_tenant_access(tenant_id));
CREATE POLICY tenant_write ON public.payroll_invoices FOR ALL TO authenticated USING (app_has_tenant_write_access(tenant_id)) WITH CHECK (app_has_tenant_write_access(tenant_id));

-- 4. Storage Bucket 'payroll_invoices' Initialization
INSERT INTO storage.buckets (id, name, public)
VALUES ('payroll_invoices', 'payroll_invoices', true)
ON CONFLICT (id) DO UPDATE SET public = true;

-- 5. 90-Day Storage & Record Auto Retention Cleanup Function
CREATE OR REPLACE FUNCTION public.cleanup_old_payroll_invoices()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_deleted_count INT;
BEGIN
    -- Delete records older than 90 days (3 months)
    WITH deleted_rows AS (
        DELETE FROM public.payroll_invoices
        WHERE created_at < NOW() - INTERVAL '90 days'
        RETURNING invoice_id, pdf_storage_path
    )
    SELECT COUNT(*) INTO v_deleted_count FROM deleted_rows;

    RETURN v_deleted_count;
END;
$$;
