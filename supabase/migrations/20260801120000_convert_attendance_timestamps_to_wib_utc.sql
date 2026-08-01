-- Migration: Convert existing attendance timestamps to true UTC format
-- Previously timestamps were recorded with local WIB values without timezone offsets,
-- causing a +7 hour double-offset shift when parsed as UTC in the application.

UPDATE public.attendance
SET 
  check_in_time = check_in_time - INTERVAL '7 hours',
  check_out_time = CASE WHEN check_out_time IS NOT NULL THEN check_out_time - INTERVAL '7 hours' ELSE NULL END,
  created_at = created_at - INTERVAL '7 hours',
  updated_at = updated_at - INTERVAL '7 hours';

UPDATE public.attendance_logs
SET 
  created_at = created_at - INTERVAL '7 hours';
