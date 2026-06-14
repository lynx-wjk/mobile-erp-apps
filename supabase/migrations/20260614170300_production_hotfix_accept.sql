-- ============================================================================
-- Phase 2 Hotfix 2: Dynamic Stages, Edit Bypass, and Stock Corrections
-- Timestamp: 20260614170300
-- ============================================================================

-- 1. DROP trigger trg_production_ensure_default_stages to allow dynamic checklist on creation
DROP TRIGGER IF EXISTS trg_production_ensure_default_stages ON public.production_progress;

-- 2. REDEPLOY: upsert_production_process_stage_for_app without Done/Stock-In lock
CREATE OR REPLACE FUNCTION public.upsert_production_process_stage_for_app(
  p_progress_id uuid,
  p_stage_key text,
  p_status text DEFAULT 'progress'::text,
  p_tailor_id uuid DEFAULT NULL::uuid,
  p_tailor_name text DEFAULT NULL::text,
  p_qty_in numeric DEFAULT NULL::numeric,
  p_qty_out numeric DEFAULT NULL::numeric,
  p_qty_reject numeric DEFAULT NULL::numeric,
  p_price_per_pcs numeric DEFAULT NULL::numeric,
  p_process_date date DEFAULT CURRENT_DATE,
  p_proof_url text DEFAULT NULL::text,
  p_note text DEFAULT NULL::text,
  p_is_skipped boolean DEFAULT false,
  p_size_breakdown jsonb DEFAULT '[]'::jsonb
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 AS $function$
declare
  v_user public.users%rowtype;
  v_progress public.production_progress%rowtype;
  v_role text;
  v_stage_key text := lower(btrim(coalesce(p_stage_key, '')));
  v_status text := lower(btrim(coalesce(p_status, 'progress')));
  v_tailor public.production_tailors%rowtype;
  v_tailor_name text := nullif(btrim(coalesce(p_tailor_name, '')), '');
  v_qty_in numeric := greatest(coalesce(p_qty_in, 0), 0);
  v_qty_out numeric := greatest(coalesce(p_qty_out, 0), 0);
  v_qty_reject numeric := greatest(coalesce(p_qty_reject, 0), 0);
  v_price numeric := greatest(coalesce(p_price_per_pcs, 0), 0);
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_sort integer;
  v_prev_qty numeric;
  v_stage_id uuid;
begin
  select *
    into v_user
  from public.users
  where user_id = auth.uid()
    and coalesce(status, 'active') = 'active'
  limit 1;

  if v_user.user_id is null then
    raise exception 'User profile tidak ditemukan.';
  end if;

  v_role := lower(coalesce(v_user.role_id, ''));

  if v_role in ('demo_super_admin', 'demo') then
    raise exception 'Demo read-only.';
  end if;

  if v_role not in ('super_admin', 'production', 'produksi', 'platform_owner') then
    raise exception 'Akses ditolak. Hanya production, super_admin, dan platform_owner yang bisa update proses produksi.';
  end if;

  if v_status not in ('pending', 'progress', 'done', 'cancelled', 'skipped') then
    v_status := 'progress';
  end if;

  if p_is_skipped then
    v_status := 'skipped';
  end if;

  select *
    into v_progress
  from public.production_progress
  where progress_id = p_progress_id
    and (v_role = 'platform_owner' or tenant_id = v_user.tenant_id)
  for update;

  if v_progress.progress_id is null then
    raise exception 'Surat Jalan/progress produksi tidak ditemukan.';
  end if;

  -- DONE/STOCK-IN UI/RPC LOCK REMOVED per updated business requirements

  if p_tailor_id is not null then
    select *
      into v_tailor
    from public.production_tailors
    where tailor_id = p_tailor_id
      and (v_role = 'platform_owner' or tenant_id = v_user.tenant_id)
      and coalesce(status, 'active') <> 'deleted'
    limit 1;

    if v_tailor.tailor_id is null then
      raise exception 'Pekerja produksi tidak ditemukan.';
    end if;
    v_tailor_name := coalesce(nullif(v_tailor.tailor_name, ''), v_tailor_name);
  end if;

  if not p_is_skipped and coalesce(v_tailor_name, '') = '' then
    raise exception 'Pekerja proses wajib diisi.';
  end if;

  if p_is_skipped and coalesce(v_note, '') = '' then
    raise exception 'Catatan wajib diisi jika proses dilewati.';
  end if;

  v_sort := public.production_stage_sort_order(v_stage_key);

  select s.qty_out
    into v_prev_qty
  from public.production_progress_stages s
  where s.progress_id = p_progress_id
    and (v_role = 'platform_owner' or s.tenant_id = v_user.tenant_id)
    and coalesce(s.is_skipped, false) = false
    and coalesce(s.status, '') <> 'skipped'
    and coalesce(s.is_active, true) = true
    and public.production_stage_sort_order(s.stage_key) < v_sort
    and coalesce(s.qty_out, 0) > 0
  order by public.production_stage_sort_order(s.stage_key) desc
  limit 1;

  if not p_is_skipped and v_prev_qty is not null and v_qty_out <> v_prev_qty and coalesce(v_note, '') = '' then
    raise exception 'Catatan wajib diisi jika qty proses berubah dari proses sebelumnya (% ke %).', v_prev_qty, v_qty_out;
  end if;

  insert into public.production_progress_stages(
    progress_id, tenant_id, stage_key, stage_label, status,
    started_at, finished_at, proof_url, note, updated_by,
    tailor_id, tailor_name, process_date, qty_in, qty_out,
    qty_reject, unit, price_per_pcs, total_amount, payment_status,
    is_skipped, skip_reason, sort_order, size_breakdown,
    is_active, deleted_at, deleted_by
  )
  values (
    p_progress_id,
    coalesce(v_progress.tenant_id, v_user.tenant_id),
    v_stage_key,
    case v_stage_key
      when 'potong_kain' then 'Potong Kain'
      when 'jahit' then 'Jahit'
      when 'lubang_kancing' then 'Lubang Kancing'
      when 'finishing' then 'Finishing'
      when 'packing' then 'Packing'
      else initcap(replace(v_stage_key, '_', ' '))
    end,
    v_status,
    case when v_status in ('progress', 'done') then now() else null end,
    case when v_status = 'done' then now() else null end,
    nullif(btrim(coalesce(p_proof_url, '')), ''),
    v_note,
    v_user.user_id,
    p_tailor_id,
    v_tailor_name,
    coalesce(p_process_date, current_date),
    v_qty_in,
    case when p_is_skipped then coalesce(v_prev_qty, v_qty_in) else v_qty_out end,
    v_qty_reject,
    'pcs',
    v_price,
    case when p_is_skipped then 0 else v_qty_out * v_price end,
    'belum_bayar',
    p_is_skipped,
    case when p_is_skipped then v_note else null end,
    v_sort,
    coalesce(p_size_breakdown, '[]'::jsonb),
    true, null, null
  )
  on conflict (progress_id, stage_key) do update
  set status = excluded.status,
      started_at = coalesce(public.production_progress_stages.started_at, excluded.started_at),
      finished_at = case when excluded.status = 'done' then now() else null end,
      proof_url = coalesce(excluded.proof_url, public.production_progress_stages.proof_url),
      note = excluded.note,
      updated_by = v_user.user_id,
      updated_at = now(),
      tailor_id = excluded.tailor_id,
      tailor_name = excluded.tailor_name,
      process_date = excluded.process_date,
      qty_in = excluded.qty_in,
      qty_out = excluded.qty_out,
      qty_reject = excluded.qty_reject,
      unit = excluded.unit,
      price_per_pcs = excluded.price_per_pcs,
      total_amount = excluded.total_amount,
      is_skipped = excluded.is_skipped,
      skip_reason = excluded.skip_reason,
      sort_order = excluded.sort_order,
      size_breakdown = excluded.size_breakdown,
      is_active = true,
      deleted_at = null,
      deleted_by = null
  returning production_progress_stages.progress_stage_id into v_stage_id;

  update public.production_progress
     set status = case when coalesce(status, 'progress') = 'pending' then 'progress' else status end,
         updated_at = now()
   where progress_id = p_progress_id
     and (v_role = 'platform_owner' or tenant_id = v_user.tenant_id);

  perform public.production_recalculate_progress_totals(p_progress_id);

  return jsonb_build_object(
    'ok', true,
    'progress_stage_id', v_stage_id,
    'stage_key', v_stage_key,
    'status', v_status,
    'qty_in', v_qty_in,
    'qty_out', case when p_is_skipped then coalesce(v_prev_qty, v_qty_in) else v_qty_out end,
    'qty_reject', v_qty_reject,
    'size_breakdown', coalesce(p_size_breakdown, '[]'::jsonb),
    'surat_jalan_number', v_progress.surat_jalan_number
  );
end;
$function$;


-- 3. Automated Stock Correction Trigger for production_progress_items
CREATE OR REPLACE FUNCTION public.fn_on_production_progress_item_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
declare
  v_progress_status text;
  v_tx_id uuid;
begin
  if TG_OP = 'DELETE' then
    select status into v_progress_status from public.production_progress where progress_id = old.progress_id;
    if v_progress_status = 'done' and old.stock_in_transaction_id is not null then
      -- Revert stock from old product only if transaction still exists in DB
      if exists (select 1 from public.stock_transactions where stock_transaction_id = old.stock_in_transaction_id) then
        update public.products
           set stock_saat_ini = coalesce(stock_saat_ini, 0) - old.qty,
               updated_at = now()
         where product_id = old.product_id;
         
        delete from public.stock_transactions
         where stock_transaction_id = old.stock_in_transaction_id;
      end if;
    end if;
    return old;
  elsif TG_OP = 'INSERT' then
    select status into v_progress_status from public.production_progress where progress_id = new.progress_id;
    if v_progress_status = 'done' and new.stock_in_transaction_id is null and coalesce(new.qty, 0) > 0 then
      v_tx_id := public.register_stock_transaction(
        new.product_id,
        'IN',
        new.qty,
        'Produksi selesai',
        concat_ws(' | ', 'Progress produksi', new.progress_id::text, new.size_label),
        null,
        null
      );
      new.stock_in_transaction_id := v_tx_id;
      
      begin
        perform public.marketplace_queue_stock_sync_for_product_change(new.product_id, 'production_progress_done');
      exception when undefined_function then
        null;
      end;
    end if;
    return new;
  elsif TG_OP = 'UPDATE' then
    select status into v_progress_status from public.production_progress where progress_id = new.progress_id;
    if v_progress_status = 'done' then
      if old.product_id = new.product_id then
        if old.qty <> new.qty then
          -- Update product stock
          update public.products
             set stock_saat_ini = coalesce(stock_saat_ini, 0) - old.qty + new.qty,
                 updated_at = now()
           where product_id = new.product_id;
           
          -- Update stock transaction
          if new.stock_in_transaction_id is not null and exists (
            select 1 from public.stock_transactions where stock_transaction_id = new.stock_in_transaction_id
          ) then
            update public.stock_transactions
               set qty = new.qty,
                   stock_after = stock_before + new.qty
             where stock_transaction_id = new.stock_in_transaction_id;
          else
            v_tx_id := public.register_stock_transaction(
              new.product_id,
              'IN',
              new.qty,
              'Produksi selesai',
              concat_ws(' | ', 'Progress produksi', new.progress_id::text, new.size_label),
              null,
              null
            );
            new.stock_in_transaction_id := v_tx_id;
          end if;
          
          begin
            perform public.marketplace_queue_stock_sync_for_product_change(new.product_id, 'production_progress_done');
          exception when undefined_function then
            null;
          end;
        end if;
      else
        -- Product ID changed: revert old, register new
        if old.stock_in_transaction_id is not null and exists (
          select 1 from public.stock_transactions where stock_transaction_id = old.stock_in_transaction_id
        ) then
          update public.products
             set stock_saat_ini = coalesce(stock_saat_ini, 0) - old.qty,
                 updated_at = now()
           where product_id = old.product_id;
           
          delete from public.stock_transactions
           where stock_transaction_id = old.stock_in_transaction_id;
        end if;
        
        v_tx_id := public.register_stock_transaction(
          new.product_id,
          'IN',
          new.qty,
          'Produksi selesai',
          concat_ws(' | ', 'Progress produksi', new.progress_id::text, new.size_label),
          null,
          null
        );
        new.stock_in_transaction_id := v_tx_id;
        
        begin
          perform public.marketplace_queue_stock_sync_for_product_change(old.product_id, 'production_progress_done');
          perform public.marketplace_queue_stock_sync_for_product_change(new.product_id, 'production_progress_done');
        exception when undefined_function then
          null;
        end;
      end if;
    end if;
    return new;
  end if;
end;
$$;

DROP TRIGGER IF EXISTS trg_production_progress_items_stock ON public.production_progress_items;
CREATE TRIGGER trg_production_progress_items_stock
BEFORE INSERT OR UPDATE ON public.production_progress_items
FOR EACH ROW EXECUTE FUNCTION public.fn_on_production_progress_item_change();

DROP TRIGGER IF EXISTS trg_production_progress_items_stock_delete ON public.production_progress_items;
CREATE TRIGGER trg_production_progress_items_stock_delete
BEFORE DELETE ON public.production_progress_items
FOR EACH ROW EXECUTE FUNCTION public.fn_on_production_progress_item_change();


-- 4. Automated Stock Correction Trigger for production_progress (for items-free flows)
CREATE OR REPLACE FUNCTION public.fn_on_production_progress_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
declare
  v_tx_id uuid;
  v_items_count integer;
begin
  if TG_OP = 'UPDATE' then
    if new.status = 'done' then
      select count(*) into v_items_count from public.production_progress_items where progress_id = new.progress_id;
      
      if v_items_count = 0 then
        if old.product_id = new.product_id then
          if old.qty <> new.qty then
            -- Update product stock
            update public.products
               set stock_saat_ini = coalesce(stock_saat_ini, 0) - old.qty + new.qty,
                   updated_at = now()
             where product_id = new.product_id;
             
            -- Update stock transaction
            if new.stock_in_transaction_id is not null and exists (
              select 1 from public.stock_transactions where stock_transaction_id = new.stock_in_transaction_id
            ) then
              update public.stock_transactions
                 set qty = new.qty,
                     stock_after = stock_before + new.qty
               where stock_transaction_id = new.stock_in_transaction_id;
            else
              v_tx_id := public.register_stock_transaction(
                new.product_id,
                'IN',
                new.qty,
                'Produksi selesai',
                concat_ws(' | ', 'Progress produksi', new.progress_id::text),
                null,
                null
              );
              new.stock_in_transaction_id := v_tx_id;
            end if;
            
            begin
              perform public.marketplace_queue_stock_sync_for_product_change(new.product_id, 'production_progress_done');
            exception when undefined_function then
              null;
            end;
          end if;
        else
          -- Product ID changed: revert old, register new
          if old.stock_in_transaction_id is not null and exists (
            select 1 from public.stock_transactions where stock_transaction_id = old.stock_in_transaction_id
          ) then
            update public.products
               set stock_saat_ini = coalesce(stock_saat_ini, 0) - old.qty,
                   updated_at = now()
             where product_id = old.product_id;
             
            delete from public.stock_transactions
             where stock_transaction_id = old.stock_in_transaction_id;
          end if;
          
          v_tx_id := public.register_stock_transaction(
            new.product_id,
            'IN',
            new.qty,
            'Produksi selesai',
            concat_ws(' | ', 'Progress produksi', new.progress_id::text),
            null,
            null
          );
          new.stock_in_transaction_id := v_tx_id;
          
          begin
            perform public.marketplace_queue_stock_sync_for_product_change(old.product_id, 'production_progress_done');
            perform public.marketplace_queue_stock_sync_for_product_change(new.product_id, 'production_progress_done');
          exception when undefined_function then
            null;
          end;
        end if;
      end if;
    end if;
  end if;
  return new;
end;
$$;

DROP TRIGGER IF EXISTS trg_production_progress_stock ON public.production_progress;
CREATE TRIGGER trg_production_progress_stock
BEFORE UPDATE ON public.production_progress
FOR EACH ROW EXECUTE FUNCTION public.fn_on_production_progress_change();
