begin;

create or replace function public.marketplace_account_auth_status()
returns jsonb
language sql
security definer
set search_path = public
as $function$
  with visible_accounts as (
    select a.*
    from public.marketplace_accounts a
    where coalesce(a.is_deleted, false) = false
      and lower(coalesce(a.status, '')) <> 'deleted'
      and (
        auth.uid() is null
        or public.app_has_tenant_access(a.tenant_id)
      )
  ),
  normalized as (
    select
      a.*,
      nullif(a.access_token_encrypted, '') is not null as has_access_token,
      nullif(a.refresh_token_encrypted, '') is not null as has_refresh_token,
      (
        nullif(a.refresh_token_encrypted, '') is not null
        and (
          a.refresh_token_expired_at is null
          or a.refresh_token_expired_at > now()
        )
      ) as auto_refresh_ready
    from visible_accounts a
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'marketplace_account_id', a.marketplace_account_id,
        'tenant_id', a.tenant_id,
        'marketplace', a.marketplace,
        'store_name', coalesce(nullif(a.store_alias, ''), nullif(a.shop_name, ''), nullif(to_jsonb(a)->>'account_name', ''), a.marketplace_account_id::text),
        'shop_name', coalesce(nullif(a.shop_name, ''), nullif(to_jsonb(a)->>'account_name', ''), a.marketplace_account_id::text),
        'environment', coalesce(a.environment, ''),
        'status', coalesce(a.status, ''),
        'has_access_token', a.has_access_token,
        'has_refresh_token', a.has_refresh_token,
        'auto_refresh_ready', a.auto_refresh_ready,
        'token_status', case
          when lower(coalesce(a.status, '')) <> 'active' then 'inactive'
          when not a.has_access_token then 'token_missing'
          when a.access_token_expired_at is null then 'token_present'
          when a.access_token_expired_at <= now() then
            case when a.auto_refresh_ready then 'access_expired_auto_refresh_ready' else 'access_expired_needs_reauth' end
          when a.access_token_expired_at <= now() + interval '24 hours' then
            case when a.auto_refresh_ready then 'auto_refresh_ready' else 'access_expiring_soon' end
          else 'token_present'
        end,
        'access_token_expired_at', a.access_token_expired_at,
        'refresh_token_expired_at', a.refresh_token_expired_at,
        'access_token_expired_at_wib', case when a.access_token_expired_at is null then null else to_char(timezone('Asia/Jakarta', a.access_token_expired_at), 'DD/MM/YYYY HH24:MI') end,
        'refresh_token_expired_at_wib', case when a.refresh_token_expired_at is null then null else to_char(timezone('Asia/Jakarta', a.refresh_token_expired_at), 'DD/MM/YYYY HH24:MI') end,
        'last_checked_at_wib', case when a.updated_at is null then null else to_char(timezone('Asia/Jakarta', a.updated_at), 'DD/MM/YYYY HH24:MI') end,
        'last_refreshed_at_wib', case when coalesce(a.reauthorized_at, a.updated_at) is null then null else to_char(timezone('Asia/Jakarta', coalesce(a.reauthorized_at, a.updated_at)), 'DD/MM/YYYY HH24:MI') end,
        'last_error', a.last_error
      )
      order by lower(coalesce(a.marketplace, '')), coalesce(a.store_alias, a.shop_name, (to_jsonb(a)->>'account_name'), '')
    ),
    '[]'::jsonb
  )
  from normalized a;
$function$;

grant execute on function public.marketplace_account_auth_status() to authenticated, service_role;

commit;
