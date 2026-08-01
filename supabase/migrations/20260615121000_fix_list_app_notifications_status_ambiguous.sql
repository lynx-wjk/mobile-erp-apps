create or replace function public.list_app_notifications_for_app(
  p_include_resolved boolean default false
)
returns table (
  notification_id uuid,
  notification_type text,
  severity text,
  title text,
  body text,
  entity_type text,
  entity_id uuid,
  metadata jsonb,
  status text,
  read_at timestamp with time zone,
  first_triggered_at timestamp with time zone,
  last_triggered_at timestamp with time zone,
  resolved_at timestamp with time zone
)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user record;
begin
  select
    u.user_id,
    u.tenant_id,
    u.role_id,
    u.status
  into v_user
  from public.users u
  where u.user_id = auth.uid();

  if not found or coalesce(v_user.status, 'inactive') <> 'active' then
    return;
  end if;

  return query
  select
    n.notification_id,
    n.notification_type,
    n.severity,
    n.title,
    n.body,
    n.entity_type,
    n.entity_id,
    n.metadata,
    n.status,
    n.read_at,
    n.first_triggered_at,
    n.last_triggered_at,
    n.resolved_at
  from public.app_notifications n
  where n.tenant_id = v_user.tenant_id
    and n.audience_role = v_user.role_id
    and (p_include_resolved or n.status = 'active')
  order by n.last_triggered_at desc
  limit 100;
end;
$function$;

grant execute on function public.list_app_notifications_for_app(boolean) to authenticated;
