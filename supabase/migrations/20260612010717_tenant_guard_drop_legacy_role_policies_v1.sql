-- Remove legacy policies that do not tenant-scope their predicates.
-- The tenant_select/insert/update/delete policies from the previous migration
-- now cover these tables.

drop policy if exists attendance_insert_self on public.attendance;
drop policy if exists attendance_select_self_hr on public.attendance;
drop policy if exists attendance_update_self on public.attendance;
drop policy if exists "users can read own attendance" on public.attendance_logs;

drop policy if exists content_proofs_insert_creator on public.content_proofs;
drop policy if exists content_proofs_select_owner_hr on public.content_proofs;
drop policy if exists content_tasks_select_owner_hr on public.content_tasks;
drop policy if exists content_tasks_update_owner_hr on public.content_tasks;

drop policy if exists finance_verifications_finance_insert on public.finance_verifications;
drop policy if exists finance_verifications_finance_select on public.finance_verifications;

drop policy if exists live_proofs_insert_host on public.live_proofs;
drop policy if exists live_proofs_select_host_hr on public.live_proofs;
drop policy if exists live_schedules_select_host_hr on public.live_schedules;
drop policy if exists live_verifications_hr_insert on public.live_verifications;

drop policy if exists photo_evidences_insert_own on public.photo_evidences;
drop policy if exists products_read_active_users on public.products;

drop policy if exists purchase_items_insert_produksi on public.purchase_items;
drop policy if exists purchase_items_select_finance_produksi on public.purchase_items;
drop policy if exists purchase_receipts_insert_produksi on public.purchase_receipts;
drop policy if exists purchase_receipts_select_finance_produksi on public.purchase_receipts;
drop policy if exists purchases_produksi_insert_own on public.purchases;
drop policy if exists purchases_produksi_select_own on public.purchases;
drop policy if exists purchases_produksi_update_own on public.purchases;

drop policy if exists stock_transactions_insert_warehouse on public.stock_transactions;
drop policy if exists stock_transactions_select_roles on public.stock_transactions;

drop policy if exists tasks_insert_admin_hr on public.tasks;
drop policy if exists tasks_select_related on public.tasks;
drop policy if exists tasks_update_related on public.tasks;

drop policy if exists users_delete_for_real_super_admin on public.users;
drop policy if exists users_insert_for_real_super_admin on public.users;
drop policy if exists users_select_for_active_app_users on public.users;
drop policy if exists users_select_self_admin_hr on public.users;
drop policy if exists users_update_for_real_super_admin on public.users;
