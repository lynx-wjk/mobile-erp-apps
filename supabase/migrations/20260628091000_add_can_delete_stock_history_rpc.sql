CREATE OR REPLACE FUNCTION public.current_user_can_delete_stock_history()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
    from public.users u
    where u.user_id = auth.uid()
      and lower(coalesce(u.role_id, '')) in ('super_admin', 'superadmin', 'owner', 'admin')
      and lower(coalesce(u.status, 'active')) = 'active'
  );
$function$;
