# Phase 8 Safe Audit: Marketplace Disconnect & Data Purge

This document details the audit of columns containing sensitive API credentials and outlines the safe purge logic required to disconnect accounts and wipe client data.

---

## 1. Token Schema Audit

Based on database structures, the following columns contain sensitive credentials:
- **Table**: `public.marketplace_accounts`
  - `access_token` (Text/Encrypted): Temporary credentials used to access Shopee/TikTok Shop APIs.
  - `refresh_token` (Text/Encrypted): Long-lived credentials used to refresh expired access tokens.
  - `token_expires_at` (Timestamp): Expiration time of the current access token.
  - `refresh_token_expires_at` (Timestamp): Expiration time of the refresh token.
  - `status` (Text): e.g. `connected`, `disconnected`, `expired`.

### Missing Columns to Add:
- `disconnected_at` (Timestamp with time zone)
- `remote_revoke_status` (Text) — records whether API revocation succeeded (e.g. `success`, `failed`, `manual_required`).

---

## 2. Purge & Disconnect Procedures

### Local Token Wipe
When a tenant disconnects a marketplace account, the tokens must be wiped immediately rather than just changing the status:
```sql
CREATE OR REPLACE FUNCTION public.marketplace_disconnect_account(
    p_account_id uuid
)
RETURNS void
SECURITY DEFINER
AS $$
BEGIN
    -- Assert that caller is authorized (Admin of the owning tenant)
    IF NOT public.is_tenant_admin(p_account_id) THEN
        RAISE EXCEPTION 'Akses ditolak: Anda tidak berwenang memutus koneksi akun ini.';
    END IF;

    UPDATE public.marketplace_accounts
    SET access_token = NULL,
        refresh_token = NULL,
        status = 'disconnected',
        disconnected_at = now(),
        remote_revoke_status = 'manual_required' -- revoking token requires external API call
    WHERE marketplace_account_id = p_account_id;
END;
$$ LANGUAGE plpgsql;
```

### Tenant Data Purge
Wiping operational data when a tenant leaves the platform:
```sql
CREATE OR REPLACE FUNCTION public.purge_tenant_operational_data(
    p_tenant_id uuid
)
RETURNS jsonb
SECURITY DEFINER
AS $$
DECLARE
    v_rows_deleted jsonb;
    v_del_orders int;
    v_del_payments int;
    v_del_progress int;
BEGIN
    -- Only Platform Owner can invoke
    IF NOT public.is_platform_owner() THEN
        RAISE EXCEPTION 'Akses ditolak: Hanya Platform Owner yang dapat menghapus data tenant.';
    END IF;

    -- Delete cascading records
    DELETE FROM public.marketplace_order_pull_jobs WHERE tenant_id = p_tenant_id;
    
    DELETE FROM public.marketplace_orders WHERE tenant_id = p_tenant_id RETURNING count(*) INTO v_del_orders;
    
    DELETE FROM public.production_tailor_payments WHERE tenant_id = p_tenant_id RETURNING count(*) INTO v_del_payments;
    
    DELETE FROM public.production_progress WHERE tenant_id = p_tenant_id RETURNING count(*) INTO v_del_progress;
    
    -- Record deletion in audit table
    INSERT INTO public.tenant_deletion_audit (tenant_id, tenant_name, deleted_by, metadata)
    VALUES (
        p_tenant_id,
        (SELECT name FROM public.tenants WHERE id = p_tenant_id),
        auth.uid(),
        jsonb_build_object('orders_deleted', v_del_orders, 'payments_deleted', v_del_payments, 'progress_deleted', v_del_progress)
    );

    -- Delete tenant record
    DELETE FROM public.tenants WHERE id = p_tenant_id;

    RETURN jsonb_build_object('ok', true, 'deleted_orders', v_del_orders, 'deleted_payments', v_del_payments, 'deleted_progress', v_del_progress);
END;
$$ LANGUAGE plpgsql;
```

---

## 3. Rollback Warning

> [!CAUTION]
> **IRREVERSIBLE OPERATION**
> Executing `purge_tenant_operational_data` deletes physical database records. Once executed, data cannot be recovered except via point-in-time database restoration. No rollback capability exists in SQL.
