-- Migration: Overtime requests, extended user payroll profiles, and attendance bug reports

-- 1. Create overtime_requests table
CREATE TABLE IF NOT EXISTS public.overtime_requests (
  overtime_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES public.app_tenants(tenant_id) ON DELETE RESTRICT,
  user_id UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  user_name TEXT,
  user_email TEXT,
  role_id TEXT,
  overtime_date DATE NOT NULL,
  start_time TEXT NOT NULL,
  end_time TEXT NOT NULL,
  duration_hours NUMERIC(6,2) NOT NULL DEFAULT 0,
  reason TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  hourly_rate NUMERIC(14,2) NOT NULL DEFAULT 25000,
  total_amount NUMERIC(14,2) NOT NULL DEFAULT 0,
  approved_by UUID REFERENCES public.users(user_id),
  approved_by_name TEXT,
  approved_at TIMESTAMP WITH TIME ZONE,
  rejection_reason TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- RLS for overtime_requests
ALTER TABLE public.overtime_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tenant_select_overtime" ON public.overtime_requests;
CREATE POLICY "tenant_select_overtime" ON public.overtime_requests
  FOR SELECT TO authenticated
  USING (app_has_tenant_access(tenant_id));

DROP POLICY IF EXISTS "tenant_write_overtime" ON public.overtime_requests;
CREATE POLICY "tenant_write_overtime" ON public.overtime_requests
  FOR ALL TO authenticated
  USING (app_has_tenant_write_access(tenant_id))
  WITH CHECK (app_has_tenant_write_access(tenant_id));

-- 2. Extend user_payroll_profiles with salary type & penalty rates
ALTER TABLE public.user_payroll_profiles
  ADD COLUMN IF NOT EXISTS salary_type TEXT DEFAULT 'monthly' CHECK (salary_type IN ('monthly', 'daily', 'hourly')),
  ADD COLUMN IF NOT EXISTS daily_rate NUMERIC(14,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS hourly_rate NUMERIC(14,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS late_penalty_per_minute NUMERIC(14,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS absent_penalty_per_day NUMERIC(14,2) DEFAULT 0;

-- 3. Create attendance_bug_reports table
CREATE TABLE IF NOT EXISTS public.attendance_bug_reports (
  report_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES public.app_tenants(tenant_id) ON DELETE RESTRICT,
  user_id UUID NOT NULL REFERENCES public.users(user_id) ON DELETE CASCADE,
  user_name TEXT,
  user_email TEXT,
  role_id TEXT,
  report_date DATE NOT NULL DEFAULT CURRENT_DATE,
  issue_type TEXT NOT NULL,
  description TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'resolved')),
  resolved_by UUID REFERENCES public.users(user_id),
  resolved_by_name TEXT,
  resolved_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- RLS for attendance_bug_reports
ALTER TABLE public.attendance_bug_reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tenant_select_bug_reports" ON public.attendance_bug_reports;
CREATE POLICY "tenant_select_bug_reports" ON public.attendance_bug_reports
  FOR SELECT TO authenticated
  USING (app_has_tenant_access(tenant_id));

DROP POLICY IF EXISTS "tenant_write_bug_reports" ON public.attendance_bug_reports;
CREATE POLICY "tenant_write_bug_reports" ON public.attendance_bug_reports
  FOR ALL TO authenticated
  USING (app_has_tenant_write_access(tenant_id))
  WITH CHECK (app_has_tenant_write_access(tenant_id));

-- Grants
GRANT ALL ON public.overtime_requests TO authenticated, service_role;
GRANT ALL ON public.attendance_bug_reports TO authenticated, service_role;
