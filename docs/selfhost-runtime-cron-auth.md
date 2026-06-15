# Self-host runtime cron auth

Marketplace cron authentication is handled through a canonical DB runtime secret.

Runtime objects:

- app_private.runtime_secrets
- app_private.get_runtime_secret(text)
- app_private.set_runtime_secret(text, text, text)
- public.verify_marketplace_cron_secret(text)

The app_private schema is private. Runtime secrets must not be exposed to anon or authenticated clients.

Cron behavior:

Marketplace cron jobs must not contain literal cron secrets. Cron commands should read the current secret at runtime:

    app_private.get_runtime_secret('marketplace_cron_secret')

This allows rotating the marketplace cron secret by updating one DB row only.

Edge Function behavior:

Marketplace Edge Functions verify incoming cron headers through:

    admin.rpc("verify_marketplace_cron_secret", { p_secret: incomingSecret })

Environment secrets are kept only as compatibility fallback.

Rotation:

    select app_private.set_runtime_secret(
      'marketplace_cron_secret',
      encode(gen_random_bytes(32), 'hex'),
      'manual rotation'
    );

Validation checklist:

- marketplace-auto-runner returns HTTP 200
- marketplace-finance-pull returns HTTP 200
- child order/status functions do not return HTTP 401
- cron.job.command does not contain literal 64-character secrets

Never commit:

- .env
- docker-compose.override.yml
- /tmp/*.txt
- files containing raw cron secrets
- backup compose files
