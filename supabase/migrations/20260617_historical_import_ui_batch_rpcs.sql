-- Historical import UI batch RPCs.
-- Safe staging/import RPCs for client-side XLSX/CSV/ZIP parsing.
-- No business-data delete. No automatic cursor finalize.

begin;

create extension if not exists pgcrypto;

create or replace function public.marketplace_import_text_num(p_value text)
returns numeric
language plpgsql
immutable
as $$
declare
  v text;
begin
  if p_value is null then return null; end if;
  v := btrim(p_value);
  if v = '' then return null; end if;

  v := regexp_replace(v, '[^0-9,\.\-]', '', 'g');

  if v = '' or v = '-' then return null; end if;

  -- Indonesian format: 1.234.567,89
  if v ~ '^-?[0-9]{1,3}(\.[0-9]{3})+(,[0-9]+)?$' then
    v := replace(replace(v, '.', ''), ',', '.');
  -- English format: 1,234,567.89
  elsif v ~ '^-?[0-9]{1,3}(,[0-9]{3})+(\.[0-9]+)?$' then
    v := replace(v, ',', '');
  -- Comma decimal only
  elsif v ~ '^-?[0-9]+,[0-9]+$' then
    v := replace(v, ',', '.');
  else
    v := replace(v, ',', '');
  end if;

  return nullif(v, '')::numeric;
exception when others then
  return null;
end;
$$;

create or replace function public.marketplace_import_text_ts(p_value text)
returns timestamptz
language plpgsql
immutable
as $$
declare
  v text;
  n numeric;
begin
  if p_value is null then return null; end if;
  v := btrim(p_value);
  if v = '' then return null; end if;

  if v ~ '^[0-9]+(\.[0-9]+)?$' then
    n := v::numeric;
    -- Excel serial date rough conversion.
    if n > 20000 and n < 80000 then
      return (timestamp '1899-12-30' + (n || ' days')::interval) at time zone 'Asia/Jakarta';
    end if;
    -- Unix seconds.
    if n > 1000000000 and n < 9999999999 then
      return to_timestamp(n);
    end if;
  end if;

  return v::timestamptz;
exception when others then
  begin
    return (v::timestamp at time zone 'Asia/Jakarta');
  exception when others then
    return null;
  end;
end;
$$;

create table if not exists public.marketplace_export_import_batches (
  marketplace_export_import_batch_id uuid primary key default gen_random_uuid(),
  tenant_id uuid null,
  marketplace_account_id uuid not null,
  marketplace text not null,
  source_type text not null default 'order_export',
  original_filename text null,
  status text not null default 'uploaded',
  total_rows integer not null default 0,
  parsed_rows integer not null default 0,
  valid_rows integer not null default 0,
  cancelled_rows integer not null default 0,
  duplicate_rows integer not null default 0,
  gross_total numeric not null default 0,
  valid_gross_total numeric not null default 0,
  validation_result jsonb not null default '{}'::jsonb,
  imported_by uuid null,
  imported_at timestamptz not null default now(),
  validated_at timestamptz null,
  finalized_at timestamptz null,
  notes text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.marketplace_export_import_rows (
  marketplace_export_import_row_id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.marketplace_export_import_batches(marketplace_export_import_batch_id) on delete cascade,
  row_index integer not null,
  raw_row jsonb not null default '{}'::jsonb,
  normalized_row jsonb not null default '{}'::jsonb,
  marketplace_order_sn text null,
  marketplace_sku text null,
  order_status text null,
  order_created_at timestamptz null,
  total_amount numeric null,
  quantity numeric null,
  validation_status text not null default 'pending',
  validation_errors jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  unique(batch_id, row_index)
);

create table if not exists public.marketplace_finance_export_import_batches (
  marketplace_finance_export_import_batch_id uuid primary key default gen_random_uuid(),
  tenant_id uuid null,
  marketplace_account_id uuid not null,
  marketplace text not null,
  source_type text not null default 'finance_income_export',
  original_filename text null,
  status text not null default 'uploaded',
  total_rows integer not null default 0,
  parsed_rows integer not null default 0,
  matched_orders integer not null default 0,
  unmatched_orders integer not null default 0,
  payout_total numeric not null default 0,
  fee_total numeric not null default 0,
  adjustment_total numeric not null default 0,
  validation_result jsonb not null default '{}'::jsonb,
  imported_by uuid null,
  imported_at timestamptz not null default now(),
  validated_at timestamptz null,
  finalized_at timestamptz null,
  notes text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.marketplace_finance_export_import_rows (
  marketplace_finance_export_import_row_id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.marketplace_finance_export_import_batches(marketplace_finance_export_import_batch_id) on delete cascade,
  row_index integer not null,
  raw_row jsonb not null default '{}'::jsonb,
  normalized_row jsonb not null default '{}'::jsonb,
  marketplace_order_sn text null,
  statement_id text null,
  payout_status text null,
  payout_amount numeric null,
  fee_amount numeric null,
  adjustment_amount numeric null,
  settlement_at timestamptz null,
  validation_status text not null default 'pending',
  validation_errors jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  unique(batch_id, row_index)
);

create index if not exists idx_marketplace_export_import_batches_account
  on public.marketplace_export_import_batches(marketplace_account_id, imported_at desc);

create index if not exists idx_marketplace_export_import_rows_batch
  on public.marketplace_export_import_rows(batch_id, row_index);

create index if not exists idx_marketplace_export_import_rows_order_sn
  on public.marketplace_export_import_rows(marketplace_order_sn);

create index if not exists idx_marketplace_finance_export_import_batches_account
  on public.marketplace_finance_export_import_batches(marketplace_account_id, imported_at desc);

create index if not exists idx_marketplace_finance_export_import_rows_batch
  on public.marketplace_finance_export_import_rows(batch_id, row_index);

create index if not exists idx_marketplace_finance_export_import_rows_order_sn
  on public.marketplace_finance_export_import_rows(marketplace_order_sn);

drop function if exists public.marketplace_create_order_export_import_batch(uuid, text, text, text, integer, integer, integer, numeric, numeric);

create function public.marketplace_create_order_export_import_batch(
  p_marketplace_account_id uuid,
  p_marketplace text,
  p_source_type text,
  p_original_filename text,
  p_total_rows integer,
  p_valid_rows integer,
  p_cancelled_rows integer,
  p_gross_total numeric,
  p_valid_gross_total numeric
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch_id uuid;
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id
  from public.marketplace_accounts
  where marketplace_account_id = p_marketplace_account_id;

  insert into public.marketplace_export_import_batches(
    tenant_id,
    marketplace_account_id,
    marketplace,
    source_type,
    original_filename,
    status,
    total_rows,
    parsed_rows,
    valid_rows,
    cancelled_rows,
    gross_total,
    valid_gross_total,
    validation_result
  )
  values (
    v_tenant_id,
    p_marketplace_account_id,
    coalesce(public.marketplace_normalize_key(p_marketplace), p_marketplace),
    coalesce(nullif(p_source_type, ''), 'order_export'),
    p_original_filename,
    'uploaded',
    coalesce(p_total_rows, 0),
    0,
    coalesce(p_valid_rows, 0),
    coalesce(p_cancelled_rows, 0),
    coalesce(p_gross_total, 0),
    coalesce(p_valid_gross_total, 0),
    jsonb_build_object('created_from', 'flutter_historical_import_ui')
  )
  returning marketplace_export_import_batch_id into v_batch_id;

  return v_batch_id;
end;
$$;

drop function if exists public.marketplace_append_order_export_import_rows(uuid, jsonb);

create function public.marketplace_append_order_export_import_rows(
  p_batch_id uuid,
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer := 0;
begin
  insert into public.marketplace_export_import_rows(
    batch_id,
    row_index,
    raw_row,
    normalized_row,
    marketplace_order_sn,
    marketplace_sku,
    order_status,
    order_created_at,
    total_amount,
    quantity,
    validation_status,
    validation_errors
  )
  select
    p_batch_id,
    coalesce((r.value->>'row_index')::integer, row_number() over()),
    coalesce(r.value->'raw', '{}'::jsonb),
    coalesce(r.value->'normalized', '{}'::jsonb),
    nullif(r.value#>>'{normalized,order_sn}', ''),
    nullif(r.value#>>'{normalized,sku}', ''),
    nullif(r.value#>>'{normalized,status}', ''),
    public.marketplace_import_text_ts(nullif(r.value#>>'{normalized,order_created_at}', '')),
    public.marketplace_import_text_num(nullif(r.value#>>'{normalized,total_amount}', '')),
    public.marketplace_import_text_num(nullif(r.value#>>'{normalized,quantity}', '')),
    case
      when nullif(r.value#>>'{normalized,order_sn}', '') is null then 'warning'
      else 'parsed'
    end,
    case
      when nullif(r.value#>>'{normalized,order_sn}', '') is null then jsonb_build_array('missing_order_sn')
      else '[]'::jsonb
    end
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) as r(value)
  on conflict (batch_id, row_index) do update set
    raw_row = excluded.raw_row,
    normalized_row = excluded.normalized_row,
    marketplace_order_sn = excluded.marketplace_order_sn,
    marketplace_sku = excluded.marketplace_sku,
    order_status = excluded.order_status,
    order_created_at = excluded.order_created_at,
    total_amount = excluded.total_amount,
    quantity = excluded.quantity,
    validation_status = excluded.validation_status,
    validation_errors = excluded.validation_errors;

  get diagnostics v_count = row_count;

  update public.marketplace_export_import_batches
  set
    parsed_rows = (
      select count(*)
      from public.marketplace_export_import_rows
      where batch_id = p_batch_id
    ),
    updated_at = now()
  where marketplace_export_import_batch_id = p_batch_id;

  return jsonb_build_object('ok', true, 'batch_id', p_batch_id, 'upserted_rows', v_count);
end;
$$;

drop function if exists public.marketplace_create_finance_income_import_batch(uuid, text, text, text, integer, numeric, numeric, numeric);

create function public.marketplace_create_finance_income_import_batch(
  p_marketplace_account_id uuid,
  p_marketplace text,
  p_source_type text,
  p_original_filename text,
  p_total_rows integer,
  p_payout_total numeric,
  p_fee_total numeric,
  p_adjustment_total numeric
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_batch_id uuid;
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id
  from public.marketplace_accounts
  where marketplace_account_id = p_marketplace_account_id;

  insert into public.marketplace_finance_export_import_batches(
    tenant_id,
    marketplace_account_id,
    marketplace,
    source_type,
    original_filename,
    status,
    total_rows,
    parsed_rows,
    payout_total,
    fee_total,
    adjustment_total,
    validation_result
  )
  values (
    v_tenant_id,
    p_marketplace_account_id,
    coalesce(public.marketplace_normalize_key(p_marketplace), p_marketplace),
    coalesce(nullif(p_source_type, ''), 'finance_income_export'),
    p_original_filename,
    'uploaded',
    coalesce(p_total_rows, 0),
    0,
    coalesce(p_payout_total, 0),
    coalesce(p_fee_total, 0),
    coalesce(p_adjustment_total, 0),
    jsonb_build_object('created_from', 'flutter_historical_import_ui')
  )
  returning marketplace_finance_export_import_batch_id into v_batch_id;

  return v_batch_id;
end;
$$;

drop function if exists public.marketplace_append_finance_income_import_rows(uuid, jsonb);

create function public.marketplace_append_finance_income_import_rows(
  p_batch_id uuid,
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer := 0;
begin
  insert into public.marketplace_finance_export_import_rows(
    batch_id,
    row_index,
    raw_row,
    normalized_row,
    marketplace_order_sn,
    statement_id,
    payout_status,
    payout_amount,
    fee_amount,
    adjustment_amount,
    settlement_at,
    validation_status,
    validation_errors
  )
  select
    p_batch_id,
    coalesce((r.value->>'row_index')::integer, row_number() over()),
    coalesce(r.value->'raw', '{}'::jsonb),
    coalesce(r.value->'normalized', '{}'::jsonb),
    nullif(r.value#>>'{normalized,order_sn}', ''),
    nullif(r.value#>>'{normalized,statement_id}', ''),
    nullif(r.value#>>'{normalized,payout_status}', ''),
    public.marketplace_import_text_num(nullif(r.value#>>'{normalized,payout_amount}', '')),
    public.marketplace_import_text_num(nullif(r.value#>>'{normalized,fee_amount}', '')),
    public.marketplace_import_text_num(nullif(r.value#>>'{normalized,adjustment_amount}', '')),
    public.marketplace_import_text_ts(nullif(r.value#>>'{normalized,settlement_at}', '')),
    case
      when nullif(r.value#>>'{normalized,order_sn}', '') is null
       and nullif(r.value#>>'{normalized,statement_id}', '') is null then 'warning'
      else 'parsed'
    end,
    case
      when nullif(r.value#>>'{normalized,order_sn}', '') is null
       and nullif(r.value#>>'{normalized,statement_id}', '') is null then jsonb_build_array('missing_order_sn_or_statement_id')
      else '[]'::jsonb
    end
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) as r(value)
  on conflict (batch_id, row_index) do update set
    raw_row = excluded.raw_row,
    normalized_row = excluded.normalized_row,
    marketplace_order_sn = excluded.marketplace_order_sn,
    statement_id = excluded.statement_id,
    payout_status = excluded.payout_status,
    payout_amount = excluded.payout_amount,
    fee_amount = excluded.fee_amount,
    adjustment_amount = excluded.adjustment_amount,
    settlement_at = excluded.settlement_at,
    validation_status = excluded.validation_status,
    validation_errors = excluded.validation_errors;

  get diagnostics v_count = row_count;

  update public.marketplace_finance_export_import_batches
  set
    parsed_rows = (
      select count(*)
      from public.marketplace_finance_export_import_rows
      where batch_id = p_batch_id
    ),
    updated_at = now()
  where marketplace_finance_export_import_batch_id = p_batch_id;

  return jsonb_build_object('ok', true, 'batch_id', p_batch_id, 'upserted_rows', v_count);
end;
$$;

grant execute on function public.marketplace_import_text_num(text) to authenticated, service_role;
grant execute on function public.marketplace_import_text_ts(text) to authenticated, service_role;
grant execute on function public.marketplace_create_order_export_import_batch(uuid, text, text, text, integer, integer, integer, numeric, numeric) to authenticated, service_role;
grant execute on function public.marketplace_append_order_export_import_rows(uuid, jsonb) to authenticated, service_role;
grant execute on function public.marketplace_create_finance_income_import_batch(uuid, text, text, text, integer, numeric, numeric, numeric) to authenticated, service_role;
grant execute on function public.marketplace_append_finance_income_import_rows(uuid, jsonb) to authenticated, service_role;

grant select, insert, update on public.marketplace_export_import_batches to authenticated, service_role;
grant select, insert, update on public.marketplace_export_import_rows to authenticated, service_role;
grant select, insert, update on public.marketplace_finance_export_import_batches to authenticated, service_role;
grant select, insert, update on public.marketplace_finance_export_import_rows to authenticated, service_role;

notify pgrst, 'reload schema';

commit;
