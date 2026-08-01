begin;

do $$
declare
  v_order_command text;
  v_status_command text;
begin
  select command
    into v_order_command
  from cron.job
  where jobname = 'marketplace-auto-runner-every-2-min'
  limit 1;

  if v_order_command is not null then
    v_order_command := replace(
      v_order_command,
      $q$'run_pending_drain', false$q$,
      $q$'run_pending_drain', true$q$
    );
    v_order_command := replace(
      v_order_command,
      $q$'run_order_status_refresh', true$q$,
      $q$'run_order_status_refresh', false$q$
    );
    v_order_command := regexp_replace(
      v_order_command,
      $q$'child_timeout_ms',\s*[0-9]+$q$,
      $q$'child_timeout_ms', 50000$q$
    );
    v_order_command := replace(
      v_order_command,
      $q$timeout_milliseconds := 30000$q$,
      $q$timeout_milliseconds := 60000$q$
    );

    if position($q$'run_order_enqueue'$q$ in v_order_command) = 0 then
      v_order_command := replace(
        v_order_command,
        $q$'run_pending_drain', true$q$,
        $q$'run_order_enqueue', true,
        'run_pending_drain', true$q$
      );
    end if;

    perform cron.alter_job(
      (select jobid::bigint
       from cron.job
       where jobname = 'marketplace-auto-runner-every-2-min'
       limit 1),
      '*/2 * * * *',
      v_order_command,
      null,
      null,
      true
    );
  end if;

  select command
    into v_status_command
  from cron.job
  where jobname = 'marketplace-status-refresh-every-10-min'
  limit 1;

  if v_status_command is not null then
    v_status_command := replace(
      v_status_command,
      $q$'run_order', false$q$,
      $q$'run_order', true$q$
    );
    v_status_command := replace(
      v_status_command,
      $q$'run_pending_drain', true$q$,
      $q$'run_pending_drain', false$q$
    );
    v_status_command := replace(
      v_status_command,
      $q$'run_order_status_refresh', false$q$,
      $q$'run_order_status_refresh', true$q$
    );
    v_status_command := regexp_replace(
      v_status_command,
      $q$'child_timeout_ms',\s*[0-9]+$q$,
      $q$'child_timeout_ms', 50000$q$
    );
    v_status_command := replace(
      v_status_command,
      $q$timeout_milliseconds := 30000$q$,
      $q$timeout_milliseconds := 60000$q$
    );

    if position($q$'run_order_enqueue'$q$ in v_status_command) = 0 then
      v_status_command := replace(
        v_status_command,
        $q$'run_pending_drain', false$q$,
        $q$'run_order_enqueue', false,
        'run_pending_drain', false$q$
      );
    end if;

    perform cron.alter_job(
      (select jobid::bigint
       from cron.job
       where jobname = 'marketplace-status-refresh-every-10-min'
       limit 1),
      '*/10 * * * *',
      v_status_command,
      null,
      null,
      true
    );
  end if;
end $$;

commit;
