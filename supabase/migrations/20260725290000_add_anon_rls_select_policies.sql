-- Migration: 20260725290000_add_anon_rls_select_policies.sql
-- Grants select RLS policies to role anon using _tenant_rpc_current_tenant_id() so RPC endpoints return full reconciled metrics for unauthenticated/anon PostgREST calls.

DROP POLICY IF EXISTS marketplace_orders_anon_select ON public.marketplace_orders;
CREATE POLICY marketplace_orders_anon_select ON public.marketplace_orders
  FOR SELECT TO anon
  USING (tenant_id = _tenant_rpc_current_tenant_id());

DROP POLICY IF EXISTS marketplace_finance_reports_anon_select ON public.marketplace_finance_reports;
CREATE POLICY marketplace_finance_reports_anon_select ON public.marketplace_finance_reports
  FOR SELECT TO anon
  USING (tenant_id = _tenant_rpc_current_tenant_id());

DROP POLICY IF EXISTS marketplace_order_items_anon_select ON public.marketplace_order_items;
CREATE POLICY marketplace_order_items_anon_select ON public.marketplace_order_items
  FOR SELECT TO anon
  USING (tenant_id = _tenant_rpc_current_tenant_id());

DROP POLICY IF EXISTS marketplace_variant_hpp_mappings_anon_select ON public.marketplace_variant_hpp_mappings;
CREATE POLICY marketplace_variant_hpp_mappings_anon_select ON public.marketplace_variant_hpp_mappings
  FOR SELECT TO anon
  USING (tenant_id = _tenant_rpc_current_tenant_id());
