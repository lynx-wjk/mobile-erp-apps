# Phase 10 Safe Analysis: Platform Owner Subscription UI

This document maps out the layout, routing, widgets, and validation parameters required to construct the Platform Owner subscription management interface in Flutter.

---

## 1. UI Pages Architecture

### Screen 1: Subscription Plans Manager
- **File Path**: `lib/features/admin/presentation/subscription_plans_page.dart`
- **Role Guard**: `AppRole.platformOwner` only.
- **RPC Dependencies**:
  - `platform_subscription_plan_list()`
  - `platform_subscription_plan_upsert()`
- **Widgets**:
  - `ListView.builder` displaying plans as custom cards.
  - Form dialog for creating/editing plans (Code, Name, Price, Billing Cycle).
- **Validation**: Price must be numeric and >= 0. Plan code must be alphanumeric and unique.

### Screen 2: Tenant Subscription Details
- **File Path**: `lib/features/admin/presentation/tenant_subscription_detail_page.dart`
- **Role Guard**: `AppRole.platformOwner` only.
- **RPC Dependencies**:
  - `platform_tenant_subscription_summary(p_tenant_id)`
  - `platform_tenant_subscription_set(p_tenant_id, p_plan_id, p_duration_days)`
- **Widgets**:
  - Current plan badge showing status (e.g. green for `active`, orange for `past_due`, red for `suspended`).
  - History log table showing previous subscription lifecycle changes.
- **Validation**: Changing subscription requires choosing a valid target plan and specifying non-negative days.

### Screen 3: Tenant Lifecycle Control Panel
- **File Path**: `lib/features/admin/presentation/tenant_lifecycle_actions_page.dart`
- **RPC Dependencies**:
  - `platform_tenant_subscription_bypass(p_tenant_id, p_bypass)`
  - `purge_tenant_operational_data(p_tenant_id)`
- **Widgets**:
  - Action cards with warning labels for high-risk actions.
  - "PURGE DATA" red button requiring the platform owner to type the tenant's name exactly as verification.
- **Validation**: Purge action requires double-confirmation and matches tenant name query.

### Screen 4: Sync & Job Monitor
- **File Path**: `lib/features/admin/presentation/platform_job_monitor_page.dart`
- **RPC Dependencies**:
  - Fetch running/failed jobs from queue.
- **Widgets**:
  - Real-time job lists displaying worker nodes, queue load, and error traces.

---

## 2. Device Test Checklist

- [ ] **Access Authorization**: Log in with an `AppRole.admin` account. Verify that navigating to `/subscription-plans` triggers a role guard error and returns the user to the login or dashboard page.
- [ ] **Form Validation**: Try saving a subscription plan with a negative price. Verify that the Form Validator intercepts the action and highlights the error.
- [ ] **Destructive Action Safeguard**: Open the Lifecycle Actions page, select a mock tenant, and press "PURGE DATA". Verify that the action button remains disabled until the exact tenant name is typed into the confirmation text field.
- [ ] **Deep-Link Intent Routing**: Trigger `mobileerp://register?invite=<token>` from an external application. Assert that the app opens from cold start and routes straight to the `RegisterPage`.
