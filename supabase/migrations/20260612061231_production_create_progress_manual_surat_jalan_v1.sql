begin;

create or replace function public.create_production_progress_full_for_app(
  p_tailor_id uuid,
  p_tailor_name text,
  p_pattern_code text,
  p_production_date date,
  p_target_finish_date date,
  p_items jsonb,
  p_deposit_amount numeric,
  p_deposit_date date,
  p_deposit_payment_status text,
  p_surat_jalan_url text,
  p_catatan text,
  p_proof_url text,
  p_surat_jalan_number text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_progress_id uuid;
  v_tenant_id uuid;
  v_surat_jalan_number text := nullif(trim(coalesce(p_surat_jalan_number, '')), '');
begin
  if v_surat_jalan_number is null then
    raise exception 'Nomor Surat Jalan wajib diisi.';
  end if;

  v_progress_id := public.create_production_progress_full_for_app(
    p_tailor_id,
    p_tailor_name,
    p_pattern_code,
    p_production_date,
    p_target_finish_date,
    p_items,
    p_deposit_amount,
    p_deposit_date,
    p_deposit_payment_status,
    p_surat_jalan_url,
    p_catatan,
    p_proof_url
  );

  select tenant_id
    into v_tenant_id
  from public.production_progress
  where progress_id = v_progress_id;

  if v_tenant_id is null then
    raise exception 'Progress produksi tidak ditemukan setelah dibuat.';
  end if;

  if exists (
    select 1
    from public.production_progress pp
    where pp.tenant_id = v_tenant_id
      and pp.progress_id <> v_progress_id
      and lower(trim(coalesce(pp.surat_jalan_number, ''))) = lower(v_surat_jalan_number)
  ) then
    raise exception 'Nomor Surat Jalan sudah dipakai.';
  end if;

  update public.production_progress
  set surat_jalan_number = v_surat_jalan_number,
      updated_at = now()
  where progress_id = v_progress_id
    and tenant_id = v_tenant_id;

  return v_progress_id;
end;
$function$;

grant execute on function public.create_production_progress_full_for_app(uuid, text, text, date, date, jsonb, numeric, date, text, text, text, text, text) to authenticated, service_role;
revoke execute on function public.create_production_progress_full_for_app(uuid, text, text, date, date, jsonb, numeric, date, text, text, text, text, text) from anon;

commit;
