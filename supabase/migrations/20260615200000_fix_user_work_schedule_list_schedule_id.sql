-- Harden attendance/work schedule tenant RPCs on self-host.
-- Fixes schedule_id/id mismatch and removes cross-tenant/null-tenant fallbacks.
--
-- Patched:
-- - user_work_schedule_list(uuid)
-- - user_work_schedule_upsert_bulk(jsonb)
-- - attendance_today_schedule(uuid, timestamptz)
-- - admin_list_attendance_logs(integer)

begin;

create or replace function public.user_work_schedule_list(
  p_user_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user public.users%rowtype;
  v_tenant uuid;
  v_role text;
  v_rows jsonb;
begin
  if auth.uid() is null then
    raise exception 'User belum login';
  end if;

  select *
    into v_user
  from public.users u
  where u.user_id = auth.uid()
    and coalesce(u.status, 'active') = 'active'
  limit 1;

  if not found then
    raise exception 'User tidak ditemukan atau nonaktif';
  end if;

  v_tenant := v_user.tenant_id;
  v_role := regexp_replace(lower(coalesce(v_user.role_id, '')), '[^a-z0-9]+', '_', 'g');

  if v_tenant is null then
    return jsonb_build_object('ok', true, 'rows', '[]'::jsonb);
  end if;

  if p_user_id is not null
     and p_user_id <> v_user.user_id
     and v_role not in ('super_admin', 'superadmin', 'admin', 'owner', 'hr') then
    raise exception 'Tidak boleh melihat jadwal user lain';
  end if;

  if p_user_id is not null and not exists (
    select 1
    from public.users target
    where target.user_id = p_user_id
      and target.tenant_id = v_tenant
  ) then
    return jsonb_build_object('ok', true, 'rows', '[]'::jsonb);
  end if;

  select coalesce(
    jsonb_agg(row_to_json(x)::jsonb order by x.user_name nulls last, x.day_of_week),
    '[]'::jsonb
  )
  into v_rows
  from (
    select
      s.schedule_id as id,
      s.schedule_id,
      s.tenant_id,
      s.user_id,
      coalesce(u.nama, u.email, s.user_id::text) as user_name,
      u.email as user_email,
      case when s.day_of_week = 7 then 0 else s.day_of_week end as day_of_week,
      to_char(s.start_time, 'HH24:MI') as start_time,
      to_char(s.end_time, 'HH24:MI') as end_time,
      coalesce(s.late_tolerance_minutes, 0) as late_tolerance_minutes,
      coalesce(nullif(s.timezone, ''), 'Asia/Jakarta') as timezone,
      coalesce(s.is_active, true) as is_active,
      s.note,
      s.updated_at
    from public.user_work_schedules s
    left join public.users u
      on u.user_id = s.user_id
     and u.tenant_id = v_tenant
    where s.tenant_id = v_tenant
      and (
        v_role in ('super_admin', 'superadmin', 'admin', 'owner', 'hr')
        or s.user_id = v_user.user_id
      )
      and (p_user_id is null or s.user_id = p_user_id)
  ) x;

  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$function$;

create or replace function public.user_work_schedule_upsert_bulk(
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user public.users%rowtype;
  v_tenant uuid;
  v_role text;
  v_row jsonb;
  v_count int := 0;
  v_user_id uuid;
  v_day int;
  v_start time;
  v_end time;
  v_tolerance int;
  v_timezone text;
  v_is_active boolean;
  v_note text;
  v_active_text text;
begin
  if auth.uid() is null then
    raise exception 'User belum login';
  end if;

  select *
    into v_user
  from public.users u
  where u.user_id = auth.uid()
    and coalesce(u.status, 'active') = 'active'
  limit 1;

  if not found then
    raise exception 'User tidak ditemukan atau nonaktif';
  end if;

  v_tenant := v_user.tenant_id;
  v_role := regexp_replace(lower(coalesce(v_user.role_id, '')), '[^a-z0-9]+', '_', 'g');

  if v_tenant is null then
    raise exception 'Tenant tidak ditemukan';
  end if;

  if v_role not in ('super_admin', 'superadmin', 'admin', 'owner', 'hr') then
    raise exception 'Hanya Super Admin/Admin/HR yang boleh mengubah jadwal kerja';
  end if;

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows harus berupa array json.';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_user_id := nullif(v_row->>'user_id', '')::uuid;
    v_day := (v_row->>'day_of_week')::int;
    if v_day = 7 then
      v_day := 0;
    end if;

    v_start := coalesce(nullif(v_row->>'start_time', '')::time, '08:00'::time);
    v_end := coalesce(nullif(v_row->>'end_time', '')::time, '17:00'::time);
    v_tolerance := greatest(0, coalesce(nullif(v_row->>'late_tolerance_minutes', '')::int, 0));
    v_timezone := coalesce(nullif(v_row->>'timezone', ''), 'Asia/Jakarta');
    v_note := nullif(trim(coalesce(v_row->>'note', '')), '');

    v_active_text := lower(trim(coalesce(v_row->>'is_active', 'true')));
    v_is_active := case
      when v_active_text in ('true', '1', 'yes', 'y', 'on') then true
      when v_active_text in ('false', '0', 'no', 'n', 'off') then false
      else true
    end;

    if v_user_id is null then
      raise exception 'user_id kosong pada rows[%]', v_count + 1;
    end if;

    if v_day not between 0 and 6 then
      raise exception 'day_of_week harus 0-6. Nilai: %', v_day;
    end if;

    if not exists (
      select 1
      from public.users target
      where target.user_id = v_user_id
        and target.tenant_id = v_tenant
        and coalesce(target.status, 'active') = 'active'
    ) then
      raise exception 'User target tidak ditemukan di tenant ini: %', v_user_id;
    end if;

    insert into public.user_work_schedules (
      tenant_id,
      user_id,
      day_of_week,
      start_time,
      end_time,
      late_tolerance_minutes,
      timezone,
      is_active,
      note,
      created_at,
      updated_at
    ) values (
      v_tenant,
      v_user_id,
      v_day,
      v_start,
      v_end,
      v_tolerance,
      v_timezone,
      v_is_active,
      v_note,
      now(),
      now()
    )
    on conflict (tenant_id, user_id, day_of_week)
    do update set
      start_time = excluded.start_time,
      end_time = excluded.end_time,
      late_tolerance_minutes = excluded.late_tolerance_minutes,
      timezone = excluded.timezone,
      is_active = excluded.is_active,
      note = excluded.note,
      updated_at = now();

    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('ok', true, 'saved', v_count);
end;
$function$;

create or replace function public.attendance_today_schedule(
  p_user_id uuid,
  p_at timestamp with time zone default now()
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user public.users%rowtype;
  v_target public.users%rowtype;
  v_tenant uuid;
  v_role text;
  v_day int;
  v_tz text := 'Asia/Jakarta';
  v_local_now timestamp;
  v_local_time time;
  v_schedule public.user_work_schedules%rowtype;
  v_late_after time;
  v_is_late boolean := false;
  v_late_minutes int := 0;
begin
  if auth.uid() is null then
    raise exception 'User belum login';
  end if;

  select *
    into v_user
  from public.users u
  where u.user_id = auth.uid()
    and coalesce(u.status, 'active') = 'active'
  limit 1;

  if not found then
    raise exception 'User tidak ditemukan atau nonaktif';
  end if;

  if p_user_id is null then
    return jsonb_build_object(
      'ok', false,
      'configured', false,
      'is_workday', false,
      'is_late', false,
      'late_minutes', 0,
      'tolerance_minutes', 0,
      'message', 'user_id kosong'
    );
  end if;

  v_tenant := v_user.tenant_id;
  v_role := regexp_replace(lower(coalesce(v_user.role_id, '')), '[^a-z0-9]+', '_', 'g');

  if v_tenant is null then
    return jsonb_build_object(
      'ok', true,
      'configured', false,
      'is_workday', false,
      'is_late', false,
      'late_minutes', 0,
      'tolerance_minutes', 0,
      'message', 'Tenant tidak ditemukan'
    );
  end if;

  select *
    into v_target
  from public.users target
  where target.user_id = p_user_id
    and target.tenant_id = v_tenant
    and coalesce(target.status, 'active') = 'active'
  limit 1;

  if not found then
    return jsonb_build_object(
      'ok', true,
      'configured', false,
      'is_workday', false,
      'is_late', false,
      'late_minutes', 0,
      'tolerance_minutes', 0,
      'message', 'Tidak ada jadwal aktif hari ini.'
    );
  end if;

  if p_user_id <> v_user.user_id
     and v_role not in ('super_admin', 'superadmin', 'admin', 'owner', 'hr') then
    raise exception 'Tidak boleh melihat jadwal user lain';
  end if;

  v_local_now := timezone(v_tz, p_at);
  v_day := extract(dow from v_local_now)::int;
  v_local_time := v_local_now::time;

  select s.*
    into v_schedule
  from public.user_work_schedules s
  where s.user_id = p_user_id
    and s.tenant_id = v_tenant
    and coalesce(s.is_active, true) = true
    and (case when s.day_of_week = 7 then 0 else s.day_of_week end) = v_day
  order by s.updated_at desc nulls last, s.created_at desc nulls last
  limit 1;

  if not found then
    return jsonb_build_object(
      'ok', true,
      'configured', false,
      'is_workday', false,
      'is_late', false,
      'late_minutes', 0,
      'tolerance_minutes', 0,
      'day_of_week', v_day,
      'message', 'Tidak ada jadwal aktif hari ini.'
    );
  end if;

  v_tz := coalesce(nullif(v_schedule.timezone, ''), 'Asia/Jakarta');
  v_local_now := timezone(v_tz, p_at);
  v_local_time := v_local_now::time;
  v_late_after := (v_schedule.start_time + make_interval(mins => greatest(0, coalesce(v_schedule.late_tolerance_minutes, 0))))::time;
  v_is_late := v_local_time > v_late_after;

  if v_is_late then
    v_late_minutes := greatest(
      0,
      floor(extract(epoch from (v_local_time - v_schedule.start_time)) / 60)::int
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'configured', true,
    'is_workday', true,
    'is_late', v_is_late,
    'late_minutes', v_late_minutes,
    'tolerance_minutes', coalesce(v_schedule.late_tolerance_minutes, 0),
    'day_of_week', v_day,
    'start_time', to_char(v_schedule.start_time, 'HH24:MI'),
    'end_time', to_char(v_schedule.end_time, 'HH24:MI'),
    'late_after_time', to_char(v_late_after, 'HH24:MI'),
    'timezone', v_tz,
    'message', case when v_is_late then 'late' else 'on_time' end
  );
end;
$function$;

create or replace function public.admin_list_attendance_logs(
  p_limit integer default 200
)
returns table(
  attendance_id uuid,
  user_id uuid,
  nama_user text,
  email_user text,
  role_id text,
  attendance_type text,
  latitude numeric,
  longitude numeric,
  accuracy numeric,
  catatan text,
  created_at timestamp with time zone
)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user public.users%rowtype;
  v_tenant uuid;
  v_role text;
begin
  if auth.uid() is null then
    raise exception 'User belum login';
  end if;

  select *
    into v_user
  from public.users u
  where u.user_id = auth.uid()
    and coalesce(u.status, 'active') = 'active'
  limit 1;

  if not found then
    raise exception 'User tidak ditemukan atau nonaktif';
  end if;

  v_tenant := v_user.tenant_id;
  v_role := regexp_replace(lower(coalesce(v_user.role_id, '')), '[^a-z0-9]+', '_', 'g');

  if v_tenant is null or v_role not in ('super_admin', 'superadmin', 'admin', 'owner', 'hr') then
    raise exception 'Hanya Super Admin/Admin/HR yang boleh melihat absensi semua karyawan';
  end if;

  return query
  select
    a.attendance_id,
    a.user_id,
    a.nama_user,
    a.email_user,
    a.role_id,
    a.attendance_type,
    a.latitude,
    a.longitude,
    a.accuracy,
    a.catatan,
    a.created_at
  from public.attendance_logs a
  join public.users u
    on u.user_id = a.user_id
   and u.tenant_id = v_tenant
  order by a.created_at desc
  limit least(greatest(coalesce(p_limit, 200), 1), 1000);
end;
$function$;

grant execute on function public.user_work_schedule_list(uuid) to authenticated;
grant execute on function public.user_work_schedule_upsert_bulk(jsonb) to authenticated;
grant execute on function public.attendance_today_schedule(uuid, timestamp with time zone) to authenticated;
grant execute on function public.admin_list_attendance_logs(integer) to authenticated;

notify pgrst, 'reload schema';

commit;
