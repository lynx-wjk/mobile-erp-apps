-- Migration: Update pg_cron job parameter max_accounts to 5
-- Date: 2026-06-16
-- Idempotent and safe: dynamically retrieves and updates existing commands.

DO $$
DECLARE
    v_cmd text;
BEGIN
    -- 1. Update marketplace-auto-runner-every-2-min
    SELECT command INTO v_cmd FROM cron.job WHERE jobname = 'marketplace-auto-runner-every-2-min';
    IF v_cmd IS NOT NULL AND v_cmd LIKE '%''max_accounts'', 1,%' THEN
        v_cmd := replace(v_cmd, '''max_accounts'', 1,', '''max_accounts'', 5,');
        PERFORM cron.schedule('marketplace-auto-runner-every-2-min', '*/2 * * * *', v_cmd);
        RAISE NOTICE 'Updated marketplace-auto-runner-every-2-min';
    END IF;

    -- 2. Update marketplace-status-refresh-every-10-min
    SELECT command INTO v_cmd FROM cron.job WHERE jobname = 'marketplace-status-refresh-every-10-min';
    IF v_cmd IS NOT NULL AND v_cmd LIKE '%''max_accounts'', 1,%' THEN
        v_cmd := replace(v_cmd, '''max_accounts'', 1,', '''max_accounts'', 5,');
        PERFORM cron.schedule('marketplace-status-refresh-every-10-min', '*/10 * * * *', v_cmd);
        RAISE NOTICE 'Updated marketplace-status-refresh-every-10-min';
    END IF;
END $$;
