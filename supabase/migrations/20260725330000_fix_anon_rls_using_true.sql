-- Migration: 20260725330000_fix_anon_rls_using_true.sql
-- Sets USING (true) for anon SELECT policies on marketplace tables to allow SECURITY DEFINER RPCs to filter tenant_id cleanly.

DROP POLICY IF EXISTS marketplace_orders_anon_select ON public.marketplace_orders;
CREATE POLICY marketplace_orders_anon_select ON public.marketplace_orders
  FOR SELECT TO anon
  USING (true);

DROP POLICY IF EXISTS marketplace_finance_reports_anon_select ON public.marketplace_finance_reports;
CREATE POLICY marketplace_finance_reports_anon_select ON public.marketplace_finance_reports
  FOR SELECT TO anon
  USING (true);

DROP POLICY IF EXISTS marketplace_order_items_anon_select ON public.marketplace_order_items;
CREATE POLICY marketplace_order_items_anon_select ON public.marketplace_order_items
  FOR SELECT TO anon
  USING (true);

DROP POLICY IF EXISTS marketplace_variant_hpp_mappings_anon_select ON public.marketplace_variant_hpp_mappings;
CREATE POLICY marketplace_variant_hpp_mappings_anon_select ON public.marketplace_variant_hpp_mappings
  FOR SELECT TO anon
  USING (true);
