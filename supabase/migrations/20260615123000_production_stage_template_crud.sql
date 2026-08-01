create table if not exists public.production_stage_templates (
  tenant_id uuid not null,
  stage_key text not null,
  stage_label text not null,
  is_active boolean not null default true,
  default_selected boolean not null default true,
  is_default boolean not null default false,
  sort_order integer not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  primary key (tenant_id, stage_key)
);

alter table public.production_stage_templates enable row level security;

create or replace function public._current_app_tenant_id()
returns uuid
language sql
security definer
set search_path to 'public'
as $$
  select u.tenant_id
  from public.users u
  where u.user_id = auth.uid()
    and coalesce(u.status, 'active') = 'active'
  limit 1;
$$;

create or replace function public._normalize_production_stage_key(p_label text)
returns text
language sql
immutable
set search_path to 'public'
as $$
  select trim(both '_' from regexp_replace(lower(coalesce(p_label, '')), '[^a-z0-9]+', '_', 'g'));
$$;

create or replace function public._seed_production_stage_templates_for_tenant(p_tenant_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if p_tenant_id is null then
    return;
  end if;

  insert into public.production_stage_templates (
    tenant_id,
    stage_key,
    stage_label,
    is_active,
    default_selected,
    is_default,
    sort_order
  )
  values
    (p_tenant_id, 'potong_kain', 'Potong Kain', true, true, true, 10),
    (p_tenant_id, 'jahit', 'Jahit', true, true, true, 20),
    (p_tenant_id, 'lubang_kancing', 'Lubang Kancing', true, false, true, 30),
    (p_tenant_id, 'finishing', 'Finishing', true, true, true, 40),
    (p_tenant_id, 'packing', 'Packing', true, true, true, 50)
  on conflict (tenant_id, stage_key) do nothing;

  insert into public.production_stage_templates (
    tenant_id,
    stage_key,
    stage_label,
    is_active,
    default_selected,
    is_default,
    sort_order
  )
  select
    p_tenant_id,
    s.stage_key,
    coalesce(nullif(max(s.stage_label), ''), initcap(replace(s.stage_key, '_', ' '))) as stage_label,
    true,
    true,
    false,
    coalesce(min(s.sort_order), 100) + 100
  from public.production_progress_stages s
  where s.tenant_id = p_tenant_id
    and s.is_active = true
    and s.stage_key is not null
    and s.stage_key <> ''
  group by s.stage_key
  on conflict (tenant_id, stage_key) do nothing;
end;
$function$;

create or replace function public.list_production_stage_templates_for_app()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_tenant_id uuid;
  v_has_any boolean;
begin
  v_tenant_id := public._current_app_tenant_id();
  if v_tenant_id is null then
    return '[]'::jsonb;
  end if;

  select exists (
    select 1
    from public.production_stage_templates t
    where t.tenant_id = v_tenant_id
  ) into v_has_any;

  if not v_has_any then
    perform public._seed_production_stage_templates_for_tenant(v_tenant_id);
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'stage_key', t.stage_key,
          'stage_label', t.stage_label,
          'is_active', t.is_active,
          'default_selected', t.default_selected,
          'is_default', t.is_default,
          'sort_order', t.sort_order
        )
        order by t.sort_order, t.stage_label
      )
      from public.production_stage_templates t
      where t.tenant_id = v_tenant_id
        and t.is_active = true
        and t.deleted_at is null
    ),
    '[]'::jsonb
  );
end;
$function$;

create or replace function public.upsert_production_stage_template_for_app(
  p_stage_key text,
  p_stage_label text,
  p_default_selected boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_tenant_id uuid;
  v_key text;
  v_label text;
  v_sort_order integer;
begin
  v_tenant_id := public._current_app_tenant_id();
  if v_tenant_id is null then
    raise exception 'User tenant tidak valid.';
  end if;

  v_key := public._normalize_production_stage_key(coalesce(nullif(p_stage_key, ''), p_stage_label));
  v_label := nullif(trim(coalesce(p_stage_label, '')), '');

  if v_key is null or v_key = '' then
    raise exception 'Key progress tidak valid.';
  end if;
  if v_label is null then
    v_label := initcap(replace(v_key, '_', ' '));
  end if;

  perform public._seed_production_stage_templates_for_tenant(v_tenant_id);

  select coalesce(max(t.sort_order), 0) + 10
  into v_sort_order
  from public.production_stage_templates t
  where t.tenant_id = v_tenant_id;

  insert into public.production_stage_templates (
    tenant_id,
    stage_key,
    stage_label,
    is_active,
    default_selected,
    is_default,
    sort_order,
    updated_at,
    deleted_at
  )
  values (
    v_tenant_id,
    v_key,
    v_label,
    true,
    coalesce(p_default_selected, true),
    false,
    v_sort_order,
    now(),
    null
  )
  on conflict (tenant_id, stage_key) do update
  set stage_label = excluded.stage_label,
      is_active = true,
      default_selected = coalesce(p_default_selected, public.production_stage_templates.default_selected),
      updated_at = now(),
      deleted_at = null;

  return jsonb_build_object(
    'ok', true,
    'stage_key', v_key,
    'stage_label', v_label
  );
end;
$function$;

create or replace function public.delete_production_stage_template_for_app(
  p_stage_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_tenant_id uuid;
  v_key text;
begin
  v_tenant_id := public._current_app_tenant_id();
  if v_tenant_id is null then
    raise exception 'User tenant tidak valid.';
  end if;

  v_key := public._normalize_production_stage_key(p_stage_key);
  if v_key is null or v_key = '' then
    raise exception 'Key progress tidak valid.';
  end if;

  update public.production_stage_templates t
  set is_active = false,
      default_selected = false,
      deleted_at = now(),
      updated_at = now()
  where t.tenant_id = v_tenant_id
    and t.stage_key = v_key;

  return jsonb_build_object(
    'ok', true,
    'stage_key', v_key
  );
end;
$function$;

revoke all on table public.production_stage_templates from anon;
grant select on table public.production_stage_templates to authenticated;

grant execute on function public.list_production_stage_templates_for_app() to authenticated;
grant execute on function public.upsert_production_stage_template_for_app(text, text, boolean) to authenticated;
grant execute on function public.delete_production_stage_template_for_app(text) to authenticated;
grant execute on function public._current_app_tenant_id() to authenticated;
grant execute on function public._normalize_production_stage_key(text) to authenticated;
grant execute on function public._seed_production_stage_templates_for_tenant(uuid) to authenticated;
