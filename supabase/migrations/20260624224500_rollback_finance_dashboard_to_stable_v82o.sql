do $$
declare
  def text;
begin
  if to_regprocedure('public.finance_dashboard_snapshot_broken_20260624(date,date,text,uuid)') is null then
    select pg_get_functiondef('public.finance_dashboard_snapshot(date,date,text,uuid)'::regprocedure)
      into def;

    def := replace(
      def,
      'FUNCTION public.finance_dashboard_snapshot(',
      'FUNCTION public.finance_dashboard_snapshot_broken_20260624('
    );

    execute def;
  end if;
end $$;

create or replace function public.finance_dashboard_snapshot(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.finance_customer_dashboard_snapshot_v24_6_82o(
    p_start,
    p_end,
    p_marketplace,
    p_account_id
  );
end $$;

grant execute on function public.finance_dashboard_snapshot(date,date,text,uuid)
  to anon, authenticated, service_role;

notify pgrst, 'reload schema';