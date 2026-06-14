update public.marketplace_order_pull_jobs
set
  priority = greatest(coalesce(priority, 0), 96),
  next_run_at = now(),
  updated_at = now(),
  last_message = coalesce(nullif(last_message, ''), 'Prioritized stale order status backlog job.')
where job_type = 'stale_order_status_backlog_90d_v1'
  and status in ('pending', 'retry');
