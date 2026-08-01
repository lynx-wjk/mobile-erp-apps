-- Migration: 20260725194000_add_sku_group_8param_overload.sql
-- Adds 8-parameter overload for finance_sku_order_details_group_20260625 so PostgREST resolves RPC calls without p_marketplace_sku and p_local_sku

CREATE OR REPLACE FUNCTION public.finance_sku_order_details_group_20260625(
  p_start date DEFAULT NULL::date,
  p_end date DEFAULT NULL::date,
  p_marketplace text DEFAULT NULL::text,
  p_account_id uuid DEFAULT NULL::uuid,
  p_search text DEFAULT NULL::text,
  p_payout_filter text DEFAULT 'all'::text,
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
begin
  return public.finance_sku_order_details_group_20260625(
    p_start => p_start,
    p_end => p_end,
    p_marketplace => p_marketplace,
    p_account_id => p_account_id,
    p_marketplace_sku => null,
    p_local_sku => null,
    p_search => p_search,
    p_payout_filter => p_payout_filter,
    p_page => p_page,
    p_page_size => p_page_size
  );
end;
$function$;
