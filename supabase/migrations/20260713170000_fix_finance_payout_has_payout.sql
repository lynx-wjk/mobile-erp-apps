CREATE OR REPLACE FUNCTION public.sync_marketplace_finance_items_to_reports()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
 declare
   v_order_id text;
   v_tenant_id uuid;
   v_marketplace_account_id uuid;
   v_marketplace text;
   v_marketplace_norm text;
   
   v_period_start date;
   v_period_end date;
   v_gross_amount numeric;
   v_gross_sales numeric;
   v_payout_amount numeric;
   v_received_amount numeric;
   v_net_settlement numeric;
   v_settlement_date date;
 begin
   if TG_OP = 'DELETE' then
     v_order_id := coalesce(nullif(OLD.order_id, ''), nullif(OLD.order_sn, ''), nullif(OLD.external_order_id, ''));
     v_tenant_id := OLD.tenant_id;
     v_marketplace_account_id := OLD.marketplace_account_id;
     v_marketplace := OLD.marketplace;
   else
     v_order_id := coalesce(nullif(NEW.order_id, ''), nullif(NEW.order_sn, ''), nullif(NEW.external_order_id, ''));
     v_tenant_id := NEW.tenant_id;
     v_marketplace_account_id := NEW.marketplace_account_id;
     v_marketplace := NEW.marketplace;
   end if;
   
   if v_order_id is null or v_tenant_id is null then
     return coalesce(NEW, OLD);
   end if;
   
   v_marketplace_norm := lower(v_marketplace);
   if v_marketplace_norm = 'tiktok' then
     v_marketplace_norm := 'tiktok_shop';
   end if;
   
   -- Aggregate values from marketplace_finance_items
   select
     min((coalesce(fi.order_created_at, fi.created_at) at time zone 'Asia/Jakarta')::date) as period_start,
     max((coalesce(fi.order_created_at, fi.created_at) at time zone 'Asia/Jakarta')::date) as period_end,
     sum(coalesce(fi.gross_amount, 0)) as gross_amount,
     sum(coalesce(fi.gross_amount, 0)) as gross_sales,
     sum(coalesce(fi.received_amount, fi.net_settlement, 0)) as payout_amount,
     sum(coalesce(fi.received_amount, fi.net_settlement, 0)) as received_amount,
     sum(coalesce(fi.net_settlement, fi.received_amount, 0)) as net_settlement,
     max(coalesce(fi.transaction_time, fi.updated_at, fi.created_at))::date as settlement_date
   into
     v_period_start, v_period_end, v_gross_amount, v_gross_sales, v_payout_amount, v_received_amount, v_net_settlement, v_settlement_date
   from public.marketplace_finance_items fi
   where fi.tenant_id = v_tenant_id
     and fi.marketplace_account_id = v_marketplace_account_id
     and (
       lower(fi.marketplace) = lower(v_marketplace)
       or (lower(fi.marketplace) in ('tiktok', 'tiktok_shop') and v_marketplace_norm = 'tiktok_shop')
     )
     and coalesce(nullif(fi.order_id, ''), nullif(fi.order_sn, ''), nullif(fi.external_order_id, '')) = v_order_id;
     
   if v_period_start is not null then
     insert into public.marketplace_finance_reports (
       tenant_id,
       marketplace_account_id,
       marketplace,
       order_id,
       report_type,
       period_start,
       period_end,
       gross_amount,
       gross_sales,
       payout_amount,
       received_amount,
       net_settlement,
       settlement_status,
       settlement_date,
       created_at,
       updated_at
     ) values (
       v_tenant_id,
       v_marketplace_account_id,
       v_marketplace_norm,
       v_order_id,
       'order_settlement',
       v_period_start,
       v_period_end,
       v_gross_amount,
       v_gross_sales,
       v_payout_amount,
       v_received_amount,
       v_net_settlement,
       'SETTLED',
       v_settlement_date,
       now(),
       now()
     )
     on conflict (tenant_id, marketplace, order_id) do update
     set
       marketplace_account_id = excluded.marketplace_account_id,
       period_start = excluded.period_start,
       period_end = excluded.period_end,
       gross_amount = excluded.gross_amount,
       gross_sales = excluded.gross_sales,
       payout_amount = excluded.payout_amount,
       received_amount = excluded.received_amount,
       net_settlement = excluded.net_settlement,
       settlement_status = 'SETTLED',
       settlement_date = excluded.settlement_date,
       updated_at = now();
   else
     update public.marketplace_finance_reports fr
     set
       gross_amount = 0,
       gross_sales = 0,
       payout_amount = 0,
       received_amount = 0,
       net_settlement = 0,
       settlement_status = 'UNSETTLED',
       updated_at = now()
     where fr.tenant_id = v_tenant_id
       and fr.marketplace = v_marketplace_norm
       and fr.order_id = v_order_id;
   end if;
   
   return coalesce(NEW, OLD);
 end;
$function$;

 CREATE OR REPLACE FUNCTION public.finance_sku_order_line_details(p_start date DEFAULT NULL::date, p_end date DEFAULT NULL::date, p_marketplace text DEFAULT NULL::text, p_account_id uuid DEFAULT NULL::uuid, p_marketplace_sku text DEFAULT NULL::text, p_local_sku text DEFAULT NULL::text, p_search text DEFAULT NULL::text, p_payout_filter text DEFAULT 'all'::text, p_page integer DEFAULT 1, p_page_size integer DEFAULT 25)
  RETURNS jsonb                                                                                                                                                                                                                                                                                                                                                                                                                     
  LANGUAGE plpgsql                                                                                                                                                                                                                                                                                                                                                                                                                  
  SECURITY DEFINER                                                                                                                                                                                                                                                                                                                                                                                                                  
  SET search_path TO 'public'                                                                                                                                                                                                                                                                                                                                                                                                       
  SET statement_timeout TO '25s'                                                                                                                                                                                                                                                                                                                                                                                                    
 AS $function$                                                                                                                                                                                                                                                                                                                                                                                                                      
 declare                                                                                                                                                                                                                                                                                                                                                                                                                            
   v_tenant_id uuid := public.app_current_tenant_id_or_default();                                                                                                                                                                                                                                                                                                                                                                   
   v_start date := coalesce(p_start, date_trunc('month', now() at time zone 'Asia/Jakarta')::date);                                                                                                                                                                                                                                                                                                                                 
   v_end date := coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date);                                                                                                                                                                                                                                                                                                                                                        
   v_marketplace text := nullif(lower(trim(coalesce(p_marketplace,''))), '');                                                                                                                                                                                                                                                                                                                                                       
   v_filter text := lower(trim(coalesce(p_payout_filter,'all')));                                                                                                                                                                                                                                                                                                                                                                   
   v_local_sku text := lower(trim(coalesce(p_local_sku,'')));                                                                                                                                                                                                                                                                                                                                                                       
   v_page integer := greatest(1, coalesce(p_page, 1));                                                                                                                                                                                                                                                                                                                                                                              
   v_page_size integer := least(100, greatest(1, coalesce(p_page_size, 25)));                                                                                                                                                                                                                                                                                                                                                       
   v_offset integer;                                                                                                                                                                                                                                                                                                                                                                                                                
   v_is_unmapped boolean := false;                                                                                                                                                                                                                                                                                                                                                                                                  
   v_rows jsonb;                                                                                                                                                                                                                                                                                                                                                                                                                    
   v_total integer;                                                                                                                                                                                                                                                                                                                                                                                                                 
 begin                                                                                                                                                                                                                                                                                                                                                                                                                              
   v_offset := (v_page - 1) * v_page_size;                                                                                                                                                                                                                                                                                                                                                                                          
                                                                                                                                                                                                                                                                                                                                                                                                                                    
   if v_marketplace in ('all','semua','_all','*','-','semua platform') then                                                                                                                                                                                                                                                                                                                                                         
     v_marketplace := null;                                                                                                                                                                                                                                                                                                                                                                                                         
   end if;                                                                                                                                                                                                                                                                                                                                                                                                                          
                                                                                                                                                                                                                                                                                                                                                                                                                                    
   if v_filter in ('','all','semua','-') then                                                                                                                                                                                                                                                                                                                                                                                       
     v_filter := 'all';                                                                                                                                                                                                                                                                                                                                                                                                             
   elsif v_filter in ('settled','released','release','payout','paid','sudah payout') then                                                                                                                                                                                                                                                                                                                                           
     v_filter := 'paid';                                                                                                                                                                                                                                                                                                                                                                                                            
   elsif v_filter in ('pending','unpaid','belum payout','no payout','missing payout') then                                                                                                                                                                                                                                                                                                                                          
     v_filter := 'unpaid';                                                                                                                                                                                                                                                                                                                                                                                                          
   end if;                                                                                                                                                                                                                                                                                                                                                                                                                          
                                                                                                                                                                                                                                                                                                                                                                                                                                    
   -- Detect UI "unmapped" label -> search for null local_sku in DB                                                                                                                                                                                                                                                                                                                                                                 
   if v_local_sku in ('unmapped','not_mapped','tidak_dipetakan','belum dipetakan','belum_dipetakan') then                                                                                                                                                                                                                                                                                                                           
     v_is_unmapped := true;                                                                                                                                                                                                                                                                                                                                                                                                         
     v_local_sku := '';                                                                                                                                                                                                                                                                                                                                                                                                             
   end if;                                                                                                                                                                                                                                                                                                                                                                                                                          
                                                                                                                                                                                                                                                                                                                                                                                                                                    
   -- Fast path for unmapped: query marketplace_order_items directly                                                                                                                                                                                                                                                                                                                                                                
   if v_is_unmapped then                                                                                                                                                                                                                                                                                                                                                                                                            
     with base as (                                                                                                                                                                                                                                                                                                                                                                                                                 
       select                                                                                                                                                                                                                                                                                                                                                                                                                       
         o.tenant_id,                                                                                                                                                                                                                                                                                                                                                                                                               
         o.marketplace,                                                                                                                                                                                                                                                                                                                                                                                                             
         coalesce(nullif(o.order_id::text,''), nullif(o.order_sn,''), o.marketplace_order_id::text) as order_key,                                                                                                                                                                                                                                                                                                                   
         o.order_created_at,                                                                                                                                                                                                                                                                                                                                                                                                        
         o.order_status,                                                                                                                                                                                                                                                                                                                                                                                                            
         o.marketplace_account_id,                                                                                                                                                                                                                                                                                                                                                                                                  
         oi.marketplace_order_item_id,                                                                                                                                                                                                                                                                                                                                                                                              
         oi.marketplace_sku,                                                                                                                                                                                                                                                                                                                                                                                                        
         oi.marketplace_seller_sku,                                                                                                                                                                                                                                                                                                                                                                                                 
         oi.seller_sku,                                                                                                                                                                                                                                                                                                                                                                                                             
         null::text as local_sku,                                                                                                                                                                                                                                                                                                                                                                                                   
         oi.marketplace_product_name,                                                                                                                                                                                                                                                                                                                                                                                               
         oi.product_name,                                                                                                                                                                                                                                                                                                                                                                                                           
         oi.marketplace_variant_name,                                                                                                                                                                                                                                                                                                                                                                                               
         oi.variant_name,                                                                                                                                                                                                                                                                                                                                                                                                           
         greatest(1, coalesce(nullif(oi.quantity,0), nullif(oi.qty,0), 1))::integer as qty,                                                                                                                                                                                                                                                                                                                                         
         coalesce(oi.gross_amount, 0)::numeric as gross_amount,                                                                                                                                                                                                                                                                                                                                                                     
         coalesce(oi.unit_gross_amount, 0)::numeric as unit_price,                                                                                                                                                                                                                                                                                                                                                                  
         oi.marketplace_product_id,                                                                                                                                                                                                                                                                                                                                                                                                 
         oi.marketplace_sku_id,                                                                                                                                                                                                                                                                                                                                                                                                     
         oi.marketplace_order_id,
         oi.product_id,
         oi.variant_id                                                                                                                                                                                                                                                                                                                                                                                                    
       from public.marketplace_order_items oi                                                                                                                                                                                                                                                                                                                                                                                       
       join public.marketplace_orders o                                                                                                                                                                                                                                                                                                                                                                                             
         on o.marketplace_order_id = oi.marketplace_order_id                                                                                                                                                                                                                                                                                                                                                                        
         and o.tenant_id = oi.tenant_id                                                                                                                                                                                                                                                                                                                                                                                             
       where oi.tenant_id = v_tenant_id                                                                                                                                                                                                                                                                                                                                                                                             
         and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date >= v_start                                                                                                                                                                                                                                                                                                   
         and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date <= v_end                                                                                                                                                                                                                                                                                                     
         and (p_account_id is null or o.marketplace_account_id = p_account_id)                                                                                                                                                                                                                                                                                                                                                      
         and (                                                                                                                                                                                                                                                                                                                                                                                                                      
           v_marketplace is null                                                                                                                                                                                                                                                                                                                                                                                                    
           or public._finance_marketplace_norm_20260624(o.marketplace)                                                                                                                                                                                                                                                                                                                                                              
              = public._finance_marketplace_norm_20260624(v_marketplace)                                                                                                                                                                                                                                                                                                                                                            
         )                                                                                                                                                                                                                                                                                                                                                                                                                          
         -- Exclude cancelled/unpaid/batal/failed/refunded orders                                                                                                                                                                                                                                                                                                                                                                   
         and not (lower(coalesce(o.order_status, '')) ~ '(cancel|canceled|cancelled|batal|return|returned|refund|refunded|unpaid|failed|reject|in_cancel)')                                                                                                                                                                                                                                                                         
         and not (lower(coalesce(o.payment_status, '')) ~ '(unpaid|failed|cancel|canceled|cancelled|refund|refunded)')                                                                                                                                                                                                                                                                                                              
         -- Exclude UUID fake orders                                                                                                                                                                                                                                                                                                                                                                                                
         and not (o.order_sn ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')                                                                                                                                                                                                                                                                                                                                   
         and not (coalesce(o.order_id, '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')                                                                                                                                                                                                                                                                                                                     
         -- unmapped: local_sku is null/empty on the item                                                                                                                                                                                                                                                                                                                                                                           
         and coalesce(nullif(trim(oi.local_sku),''), nullif(trim(oi.mapped_local_sku),'')) is null                                                                                                                                                                                                                                                                                                                                  
         -- Filter by p_marketplace_sku and p_search in unmapped path                                                                                                                                                                                                                                                                                                                                                               
         and (                                                                                                                                                                                                                                                                                                                                                                                                                      
           p_marketplace_sku is null or p_marketplace_sku = ''                                                                                                                                                                                                                                                                                                                                                                      
           or coalesce(nullif(oi.variant_id::text,''), nullif(oi.product_id::text,''), oi.product_name, oi.marketplace_sku) = p_marketplace_sku
           or lower(p_marketplace_sku) in (                                                                                                                                                                                                                                                                                                                                                                                         
              lower(oi.marketplace_sku::text),                                                                                                                                                                                                                                                                                                                                                                                      
              lower(oi.marketplace_seller_sku::text),                                                                                                                                                                                                                                                                                                                                                                               
              lower(oi.seller_sku::text),                                                                                                                                                                                                                                                                                                                                                                                           
              lower(oi.marketplace_sku_id::text),                                                                                                                                                                                                                                                                                                                                                                                   
              lower(oi.marketplace_product_id::text),
              lower(oi.variant_id::text),
              lower(oi.product_id::text)
           )                                                                                                                                                                                                                                                                                                                                                                                                                        
         )                                                                                                                                                                                                                                                                                                                                                                                                                          
         and (                                                                                                                                                                                                                                                                                                                                                                                                                      
           p_search is null or p_search = ''                                                                                                                                                                                                                                                                                                                                                                                        
           or o.order_id::text ilike '%' || p_search || '%'                                                                                                                                                                                                                                                                                                                                                                         
           or coalesce(oi.marketplace_product_name, oi.product_name, '') ilike '%' || p_search || '%'                                                                                                                                                                                                                                                                                                                               
           or ('unmapped ' || coalesce(nullif(oi.variant_id::text,''), nullif(oi.product_id::text,''), oi.marketplace_product_id::text, '') || ' ' || coalesce(oi.marketplace_sku, '') || ' ' || coalesce(oi.marketplace_seller_sku, '') || ' ' || coalesce(oi.product_name, '')) = p_search
         )                                                                                                                                                                                                                                                                                                                                                                                                                          
     ),                                                                                                                                                                                                                                                                                                                                                                                                                             
     unmapped_base as (                                                                                                                                                                                                                                                                                                                                                                                                             
       select b.*                                                                                                                                                                                                                                                                                                                                                                                                                   
       from base b                                                                                                                                                                                                                                                                                                                                                                                                                  
       left join lateral (                                                                                                                                                                                                                                                                                                                                                                                                          
         select m.local_sku                                                                                                                                                                                                                                                                                                                                                                                                         
         from public.marketplace_sku_maps m                                                                                                                                                                                                                                                                                                                                                                                         
         where m.tenant_id = b.tenant_id                                                                                                                                                                                                                                                                                                                                                                                            
           and m.marketplace_account_id = b.marketplace_account_id                                                                                                                                                                                                                                                                                                                                                                  
           and m.marketplace_product_id = b.marketplace_product_id                                                                                                                                                                                                                                                                                                                                                                  
           and m.marketplace_sku_id = b.marketplace_sku_id                                                                                                                                                                                                                                                                                                                                                                          
           and coalesce(m.status, 'active') = 'active'                                                                                                                                                                                                                                                                                                                                                                              
         limit 1                                                                                                                                                                                                                                                                                                                                                                                                                    
       ) m on true                                                                                                                                                                                                                                                                                                                                                                                                                  
       where m.local_sku is null                                                                                                                                                                                                                                                                                                                                                                                                    
     ),                                                                                                                                                                                                                                                                                                                                                                                                                             
     with_payout as (                                                                                                                                                                                                                                                                                                                                                                                                               
       select                                                                                                                                                                                                                                                                                                                                                                                                                       
         u.*,                                                                                                                                                                                                                                                                                                                                                                                                                       
         coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)::numeric as order_payout,
          (fr.finance_report_id is not null and (coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0) <> 0 or upper(coalesce(fr.settlement_status, '')) ~ '(SETTLED|PAID|RELEASE|PAYOUT_MINUS|NEGATIVE_PAYOUT)')) as has_payout,
          (fr.finance_report_id is not null) as finance_report_exists,
          (coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0) > 0) as positive_payout_exists,
          fr.settlement_status as finance_status                                                                                                                                                                                                                                                                                                                                                                           
       from unmapped_base u                                                                                                                                                                                                                                                                                                                                                                                                         
       left join lateral (                                                                                                                                                                                                                                                                                                                                                                                                          
         select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement, fr.settlement_status from (                                                                                                                                                                                                                                                                                                                                                                                                                     
           select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement, fr.settlement_status, 1 as priority                                                                                                                                                                                                                                                                                                                      
           from public.marketplace_finance_reports fr                                                                                                                                                                                                                                                                                                                                                                               
           where fr.tenant_id = u.tenant_id                                                                                                                                                                                                                                                                                                                                                                                         
             and fr.marketplace_account_id = u.marketplace_account_id                                                                                                                                                                                                                                                                                                                                                               
             and fr.order_id = u.order_key                                                                                                                                                                                                                                                                                                                                                                                          
             and coalesce(fr.report_type, '') <> 'statement'                                                                                                                                                                                                                                                                                                                                                                        
           union all                                                                                                                                                                                                                                                                                                                                                                                                                
           select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement, fr.settlement_status, 2 as priority                                                                                                                                                                                                                                                                                                                      
           from public.marketplace_finance_reports fr                                                                                                                                                                                                                                                                                                                                                                               
           where fr.tenant_id = u.tenant_id                                                                                                                                                                                                                                                                                                                                                                                         
             and fr.marketplace_account_id = u.marketplace_account_id                                                                                                                                                                                                                                                                                                                                                               
             and fr.marketplace_order_id = u.marketplace_order_id                                                                                                                                                                                                                                                                                                                                                                   
             and coalesce(fr.report_type, '') <> 'statement'                                                                                                                                                                                                                                                                                                                                                                        
         ) fr                                                                                                                                                                                                                                                                                                                                                                                                                       
         order by priority                                                                                                                                                                                                                                                                                                                                                                                                          
         limit 1                                                                                                                                                                                                                                                                                                                                                                                                                    
       ) fr on true                                                                                                                                                                                                                                                                                                                                                                                                                 
     ),                                                                                                                                                                                                                                                                                                                                                                                                                             
     filtered as (                                                                                                                                                                                                                                                                                                                                                                                                                  
       select *                                                                                                                                                                                                                                                                                                                                                                                                                     
       from with_payout                                                                                                                                                                                                                                                                                                                                                                                                             
       where                                                                                                                                                                                                                                                                                                                                                                                                                        
         v_filter = 'all'                                                                                                                                                                                                                                                                                                                                                                                                           
         or (v_filter = 'paid' and has_payout)                                                                                                                                                                                                                                                                                                                                                                                      
         or (v_filter = 'unpaid' and not has_payout)                                                                                                                                                                                                                                                                                                                                                                                
     ),                                                                                                                                                                                                                                                                                                                                                                                                                             
     counted as (                                                                                                                                                                                                                                                                                                                                                                                                                   
       select count(*)::integer as total from filtered                                                                                                                                                                                                                                                                                                                                                                              
     ),                                                                                                                                                                                                                                                                                                                                                                                                                             
     paged as (                                                                                                                                                                                                                                                                                                                                                                                                                     
       select * from filtered                                                                                                                                                                                                                                                                                                                                                                                                       
       order by order_created_at desc, order_key, marketplace_order_item_id                                                                                                                                                                                                                                                                                                                                                         
       limit v_page_size offset v_offset                                                                                                                                                                                                                                                                                                                                                                                            
     )                                                                                                                                                                                                                                                                                                                                                                                                                              
     select                                                                                                                                                                                                                                                                                                                                                                                                                         
       coalesce(jsonb_agg(                                                                                                                                                                                                                                                                                                                                                                                                          
         jsonb_build_object(                                                                                                                                                                                                                                                                                                                                                                                                        
           'id', marketplace_order_item_id,                                                                                                                                                                                                                                                                                                                                                                                         
           'order_id', order_key,                                                                                                                                                                                                                                                                                                                                                                                                   
           'order_sn', order_key,                                                                                                                                                                                                                                                                                                                                                                                                   
           'marketplace', marketplace,                                                                                                                                                                                                                                                                                                                                                                                              
           'marketplace_name', marketplace,                                                                                                                                                                                                                                                                                                                                                                                         
           'created_at', order_created_at,                                                                                                                                                                                                                                                                                                                                                                                          
           'order_status', order_status,                                                                                                                                                                                                                                                                                                                                                                                            
           'status', order_status,                                                                                                                                                                                                                                                                                                                                                                                                  
           'product_name', coalesce(marketplace_product_name, product_name, '-'),                                                                                                                                                                                                                                                                                                                                                   
           'variant_name', coalesce(marketplace_variant_name, variant_name, '-'),                                                                                                                                                                                                                                                                                                                                                   
           'marketplace_sku', coalesce(marketplace_sku, marketplace_seller_sku, seller_sku, '-'),                                                                                                                                                                                                                                                                                                                                   
           'local_sku', 'Unmapped',                                                                                                                                                                                                                                                                                                                                                                                                 
           'qty', qty,                                                                                                                                                                                                                                                                                                                                                                                                              
           'quantity', qty,                                                                                                                                                                                                                                                                                                                                                                                                         
           'gross_amount', gross_amount,                                                                                                                                                                                                                                                                                                                                                                                            
           'unit_price', unit_price,
            'order_payout', order_payout,
            'has_payout', has_payout,
            'finance_report_exists', finance_report_exists,
            'positive_payout_exists', positive_payout_exists,
            'finance_status', coalesce(finance_status, ''),
            'payout_status', coalesce(finance_status, '')                                                                                                                                                                                                                                                                                                                                                                                                 
         ) order by order_created_at desc, order_key                                                                                                                                                                                                                                                                                                                                                                                
       ), '[]'::jsonb),                                                                                                                                                                                                                                                                                                                                                                                                             
       (select coalesce(max(total),0) from counted)                                                                                                                                                                                                                                                                                                                                                                                 
     into v_rows, v_total                                                                                                                                                                                                                                                                                                                                                                                                           
     from paged;                                                                                                                                                                                                                                                                                                                                                                                                                    
                                                                                                                                                                                                                                                                                                                                                                                                                                    
     return jsonb_build_object(                                                                                                                                                                                                                                                                                                                                                                                                     
       'ok', true,                                                                                                                                                                                                                                                                                                                                                                                                                  
       'source', 'unmapped_direct_join',                                                                                                                                                                                                                                                                                                                                                                                            
       'rows', v_rows,                                                                                                                                                                                                                                                                                                                                                                                                              
       'total', v_total,                                                                                                                                                                                                                                                                                                                                                                                                            
       'page', v_page,                                                                                                                                                                                                                                                                                                                                                                                                              
       'page_size', v_page_size,                                                                                                                                                                                                                                                                                                                                                                                                    
       'total_pages', ceil(v_total::numeric / v_page_size::numeric),                                                                                                                                                                                                                                                                                                                                                                
       'total_count', v_total,                                                                                                                                                                                                                                                                                                                                                                                                      
       'summary_source', 'marketplace_order_items'                                                                                                                                                                                                                                                                                                                                                                                  
     );                                                                                                                                                                                                                                                                                                                                                                                                                             
   end if;                                                                                                                                                                                                                                                                                                                                                                                                                          
                                                                                                                                                                                                                                                                                                                                                                                                                                    
   -- Default mapped logic                                                                                                                                                                                                                                                                                                                                                                                                          
   with base_items as (                                                                                                                                                                                                                                                                                                                                                                                                             
     select                                                                                                                                                                                                                                                                                                                                                                                                                         
       i.marketplace_order_item_id,                                                                                                                                                                                                                                                                                                                                                                                                 
       i.marketplace_order_id,                                                                                                                                                                                                                                                                                                                                                                                                      
       o.marketplace,                                                                                                                                                                                                                                                                                                                                                                                                               
       o.marketplace_account_id,                                                                                                                                                                                                                                                                                                                                                                                                    
       coalesce(nullif(o.order_id::text,''), nullif(o.order_sn,''), o.marketplace_order_id::text) as order_key,                                                                                                                                                                                                                                                                                                                     
       o.order_created_at,                                                                                                                                                                                                                                                                                                                                                                                                          
       o.order_status,                                                                                                                                                                                                                                                                                                                                                                                                              
       i.marketplace_product_name,                                                                                                                                                                                                                                                                                                                                                                                                  
       i.product_name,                                                                                                                                                                                                                                                                                                                                                                                                              
       i.marketplace_variant_name,                                                                                                                                                                                                                                                                                                                                                                                                  
       i.variant_name,                                                                                                                                                                                                                                                                                                                                                                                                              
       i.marketplace_sku,                                                                                                                                                                                                                                                                                                                                                                                                           
       i.marketplace_seller_sku,                                                                                                                                                                                                                                                                                                                                                                                                    
       i.seller_sku,                                                                                                                                                                                                                                                                                                                                                                                                                
       coalesce(nullif(trim(i.local_sku),''), nullif(trim(i.mapped_local_sku),'')) as local_sku,                                                                                                                                                                                                                                                                                                                                    
       greatest(1, coalesce(nullif(i.quantity,0), nullif(i.qty,0), 1))::integer as qty,                                                                                                                                                                                                                                                                                                                                             
       coalesce(i.gross_amount, 0)::numeric as gross_amount,                                                                                                                                                                                                                                                                                                                                                                        
       coalesce(i.unit_gross_amount, 0)::numeric as unit_price,
       i.marketplace_sku_id,
       i.marketplace_product_id,
       i.variant_id,
       i.product_id
     from public.marketplace_order_items i                                                                                                                                                                                                                                                                                                                                                                                          
     join public.marketplace_orders o                                                                                                                                                                                                                                                                                                                                                                                               
       on o.marketplace_order_id = i.marketplace_order_id                                                                                                                                                                                                                                                                                                                                                                           
       and o.tenant_id = i.tenant_id                                                                                                                                                                                                                                                                                                                                                                                                
     where i.tenant_id = v_tenant_id                                                                                                                                                                                                                                                                                                                                                                                                
       and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date >= v_start                                                                                                                                                                                                                                                                                                     
       and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date <= v_end                                                                                                                                                                                                                                                                                                       
       and (p_account_id is null or o.marketplace_account_id = p_account_id)                                                                                                                                                                                                                                                                                                                                                        
       and (                                                                                                                                                                                                                                                                                                                                                                                                                        
         v_marketplace is null                                                                                                                                                                                                                                                                                                                                                                                                      
         or public._finance_marketplace_norm_20260624(o.marketplace)                                                                                                                                                                                                                                                                                                                                                                
            = public._finance_marketplace_norm_20260624(v_marketplace)                                                                                                                                                                                                                                                                                                                                                              
       )                                                                                                                                                                                                                                                                                                                                                                                                                            
       -- Exclude cancelled/unpaid/batal/failed/refunded orders                                                                                                                                                                                                                                                                                                                                                                     
       and not (lower(coalesce(o.order_status, '')) ~ '(cancel|canceled|cancelled|batal|return|returned|refund|refunded|unpaid|failed|reject|in_cancel)')                                                                                                                                                                                                                                                                           
       and not (lower(coalesce(o.payment_status, '')) ~ '(unpaid|failed|cancel|canceled|cancelled|refund|refunded)')                                                                                                                                                                                                                                                                                                                
       -- Exclude UUID fake orders                                                                                                                                                                                                                                                                                                                                                                                                  
       and not (o.order_sn ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')                                                                                                                                                                                                                                                                                                                                     
       and not (coalesce(o.order_id, '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')                                                                                                                                                                                                                                                                                                                       
   ),                                                                                                                                                                                                                                                                                                                                                                                                                               
   hpp_resolved as (                                                                                                                                                                                                                                                                                                                                                                                                                
     select                                                                                                                                                                                                                                                                                                                                                                                                                         
       b.marketplace_order_item_id,                                                                                                                                                                                                                                                                                                                                                                                                 
       coalesce(                                                                                                                                                                                                                                                                                                                                                                                                                    
         b.local_sku,                                                                                                                                                                                                                                                                                                                                                                                                               
         hm_sku.local_sku,                                                                                                                                                                                                                                                                                                                                                                                                          
         hm_sel.local_sku                                                                                                                                                                                                                                                                                                                                                                                                           
       ) as effective_local_sku                                                                                                                                                                                                                                                                                                                                                                                                     
     from base_items b                                                                                                                                                                                                                                                                                                                                                                                                              
     left join lateral (                                                                                                                                                                                                                                                                                                                                                                                                            
       select hm.local_sku                                                                                                                                                                                                                                                                                                                                                                                                          
       from public.marketplace_variant_hpp_mappings hm                                                                                                                                                                                                                                                                                                                                                                              
       where hm.tenant_id = v_tenant_id                                                                                                                                                                                                                                                                                                                                                                                             
         and hm.marketplace_account_id = b.marketplace_account_id                                                                                                                                                                                                                                                                                                                                                                   
         and lower(nullif(hm.marketplace_sku_id,'')) = lower(nullif(coalesce(b.marketplace_sku, b.marketplace_seller_sku, b.seller_sku),''))                                                                                                                                                                                                                                                                                        
         and coalesce(hm.is_active, true) = true                                                                                                                                                                                                                                                                                                                                                                                    
         and nullif(hm.local_sku,'') is not null                                                                                                                                                                                                                                                                                                                                                                                    
       order by hm.updated_at desc nulls last                                                                                                                                                                                                                                                                                                                                                                                       
       limit 1                                                                                                                                                                                                                                                                                                                                                                                                                      
     ) hm_sku on true                                                                                                                                                                                                                                                                                                                                                                                                               
     left join lateral (                                                                                                                                                                                                                                                                                                                                                                                                            
       select hm.local_sku                                                                                                                                                                                                                                                                                                                                                                                                          
       from public.marketplace_variant_hpp_mappings hm                                                                                                                                                                                                                                                                                                                                                                              
       where hm.tenant_id = v_tenant_id                                                                                                                                                                                                                                                                                                                                                                                             
         and hm.marketplace_account_id = b.marketplace_account_id                                                                                                                                                                                                                                                                                                                                                                   
         and lower(nullif(hm.marketplace_seller_sku,'')) = lower(nullif(coalesce(b.marketplace_seller_sku, b.marketplace_sku),''))                                                                                                                                                                                                                                                                                                  
         and coalesce(hm.is_active, true) = true                                                                                                                                                                                                                                                                                                                                                                                    
         and nullif(hm.local_sku,'') is not null                                                                                                                                                                                                                                                                                                                                                                                    
       order by hm.updated_at desc nulls last                                                                                                                                                                                                                                                                                                                                                                                       
       limit 1                                                                                                                                                                                                                                                                                                                                                                                                                      
     ) hm_sel on true                                                                                                                                                                                                                                                                                                                                                                                                               
   ),                                                                                                                                                                                                                                                                                                                                                                                                                               
   match_sku as (                                                                                                                                                                                                                                                                                                                                                                                                                   
     select b.*, hr.effective_local_sku                                                                                                                                                                                                                                                                                                                                                                                             
     from base_items b                                                                                                                                                                                                                                                                                                                                                                                                              
     join hpp_resolved hr on hr.marketplace_order_item_id = b.marketplace_order_item_id                                                                                                                                                                                                                                                                                                                                             
     where                                                                                                                                                                                                                                                                                                                                                                                                                          
       (
         p_marketplace_sku is null or p_marketplace_sku = ''
         or coalesce(nullif(b.variant_id::text,''), nullif(b.product_id::text,''), b.product_name, b.marketplace_sku) = p_marketplace_sku
         or lower(p_marketplace_sku) in (
            lower(b.marketplace_sku::text),
            lower(b.marketplace_seller_sku::text),
            lower(b.seller_sku::text),
            lower(b.marketplace_sku_id::text),
            lower(b.marketplace_product_id::text),
            lower(b.variant_id::text),
            lower(b.product_id::text)
         )
       )
       and (
         v_local_sku is null or v_local_sku = ''
         or lower(coalesce(hr.effective_local_sku,'')) = v_local_sku
       )
       and (
         p_search is null or p_search = ''
         or b.order_key ilike '%' || p_search || '%'
         or coalesce(b.marketplace_product_name, b.product_name, '') ilike '%' || p_search || '%'
         or ('mapped ' || coalesce(nullif(b.variant_id::text,''), nullif(b.product_id::text,''), b.marketplace_product_id::text, '') || ' ' || coalesce(b.marketplace_sku, '') || ' ' || coalesce(b.marketplace_seller_sku, '') || ' ' || coalesce(b.product_name, '') || ' ' || coalesce(hr.effective_local_sku, '')) ilike '%' || p_search || '%'
       )                                                                                                                                                                                                                                                                                                                                                                                                                            
   ),                                                                                                                                                                                                                                                                                                                                                                                                                               
   with_payout as (                                                                                                                                                                                                                                                                                                                                                                                                                 
     select                                                                                                                                                                                                                                                                                                                                                                                                                         
       m.*,                                                                                                                                                                                                                                                                                                                                                                                                                         
       coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)::numeric as order_payout,
          (fr.finance_report_id is not null and (coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0) <> 0 or upper(coalesce(fr.settlement_status, '')) ~ '(SETTLED|PAID|RELEASE|PAYOUT_MINUS|NEGATIVE_PAYOUT)')) as has_payout,
          (fr.finance_report_id is not null) as finance_report_exists,
          (coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0) > 0) as positive_payout_exists,
          fr.settlement_status as finance_status                                                                                                                                                                                                                                                                                                                                                                             
     from match_sku m                                                                                                                                                                                                                                                                                                                                                                                                               
     left join lateral (                                                                                                                                                                                                                                                                                                                                                                                                            
       select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement, fr.settlement_status from (                                                                                                                                                                                                                                                                                                                                                                                                                       
         select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement, fr.settlement_status, 1 as priority                                                                                                                                                                                                                                                                                                                        
         from public.marketplace_finance_reports fr                                                                                                                                                                                                                                                                                                                                                                                 
         where fr.tenant_id = v_tenant_id                                                                                                                                                                                                                                                                                                                                                                                           
           and fr.marketplace_account_id = m.marketplace_account_id                                                                                                                                                                                                                                                                                                                                                                 
           and fr.order_id = m.order_key                                                                                                                                                                                                                                                                                                                                                                                            
           and coalesce(fr.report_type, '') <> 'statement'                                                                                                                                                                                                                                                                                                                                                                          
         union all                                                                                                                                                                                                                                                                                                                                                                                                                  
         select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement, fr.settlement_status, 2 as priority                                                                                                                                                                                                                                                                                                                        
         from public.marketplace_finance_reports fr                                                                                                                                                                                                                                                                                                                                                                                 
         where fr.tenant_id = v_tenant_id                                                                                                                                                                                                                                                                                                                                                                                           
           and fr.marketplace_account_id = m.marketplace_account_id                                                                                                                                                                                                                                                                                                                                                                 
           and fr.marketplace_order_id = m.marketplace_order_id                                                                                                                                                                                                                                                                                                                                                                     
           and coalesce(fr.report_type, '') <> 'statement'                                                                                                                                                                                                                                                                                                                                                                          
       ) fr                                                                                                                                                                                                                                                                                                                                                                                                                         
       order by priority                                                                                                                                                                                                                                                                                                                                                                                                            
       limit 1                                                                                                                                                                                                                                                                                                                                                                                                                      
     ) fr on true                                                                                                                                                                                                                                                                                                                                                                                                                   
   ),                                                                                                                                                                                                                                                                                                                                                                                                                               
   filtered as (                                                                                                                                                                                                                                                                                                                                                                                                                    
     select *                                                                                                                                                                                                                                                                                                                                                                                                                       
     from with_payout                                                                                                                                                                                                                                                                                                                                                                                                               
     where                                                                                                                                                                                                                                                                                                                                                                                                                          
       v_filter = 'all'                                                                                                                                                                                                                                                                                                                                                                                                             
       or (v_filter = 'paid' and has_payout)                                                                                                                                                                                                                                                                                                                                                                                        
       or (v_filter = 'unpaid' and not has_payout)                                                                                                                                                                                                                                                                                                                                                                                  
   ),                                                                                                                                                                                                                                                                                                                                                                                                                               
   counted as (                                                                                                                                                                                                                                                                                                                                                                                                                     
     select count(*)::integer as total from filtered                                                                                                                                                                                                                                                                                                                                                                                
   ),                                                                                                                                                                                                                                                                                                                                                                                                                               
   paged as (                                                                                                                                                                                                                                                                                                                                                                                                                       
     select * from filtered                                                                                                                                                                                                                                                                                                                                                                                                         
     order by order_created_at desc, order_key, marketplace_order_item_id                                                                                                                                                                                                                                                                                                                                                           
     limit v_page_size offset v_offset                                                                                                                                                                                                                                                                                                                                                                                              
   )                                                                                                                                                                                                                                                                                                                                                                                                                                
   select                                                                                                                                                                                                                                                                                                                                                                                                                           
     coalesce(jsonb_agg(                                                                                                                                                                                                                                                                                                                                                                                                            
       jsonb_build_object(                                                                                                                                                                                                                                                                                                                                                                                                          
         'id', marketplace_order_item_id,                                                                                                                                                                                                                                                                                                                                                                                           
         'order_id', order_key,                                                                                                                                                                                                                                                                                                                                                                                                     
         'order_sn', order_key,                                                                                                                                                                                                                                                                                                                                                                                                     
         'marketplace', marketplace,                                                                                                                                                                                                                                                                                                                                                                                                
         'marketplace_name', marketplace,                                                                                                                                                                                                                                                                                                                                                                                           
         'created_at', order_created_at,                                                                                                                                                                                                                                                                                                                                                                                            
         'order_status', order_status,                                                                                                                                                                                                                                                                                                                                                                                              
         'status', order_status,                                                                                                                                                                                                                                                                                                                                                                                                    
         'product_name', coalesce(marketplace_product_name, product_name, '-'),                                                                                                                                                                                                                                                                                                                                                     
         'variant_name', coalesce(marketplace_variant_name, variant_name, '-'),                                                                                                                                                                                                                                                                                                                                                     
         'marketplace_sku', coalesce(marketplace_sku, marketplace_seller_sku, seller_sku, marketplace_sku_id::text, marketplace_product_id::text, '-'),                                                                                                                                                                                                                                                                             
         'local_sku', effective_local_sku,                                                                                                                                                                                                                                                                                                                                                                                          
         'qty', qty,                                                                                                                                                                                                                                                                                                                                                                                                                
         'quantity', qty,                                                                                                                                                                                                                                                                                                                                                                                                           
         'gross_amount', gross_amount,                                                                                                                                                                                                                                                                                                                                                                                              
         'unit_price', unit_price,
            'order_payout', order_payout,
            'has_payout', has_payout,
            'finance_report_exists', finance_report_exists,
            'positive_payout_exists', positive_payout_exists,
            'finance_status', coalesce(finance_status, ''),
            'payout_status', coalesce(finance_status, '')                                                                                                                                                                                                                                                                                                                                                                                                   
       ) order by order_created_at desc, order_key                                                                                                                                                                                                                                                                                                                                                                                  
     ), '[]'::jsonb),                                                                                                                                                                                                                                                                                                                                                                                                               
     (select coalesce(max(total),0) from counted)                                                                                                                                                                                                                                                                                                                                                                                   
   into v_rows, v_total                                                                                                                                                                                                                                                                                                                                                                                                             
   from paged;                                                                                                                                                                                                                                                                                                                                                                                                                      
                                                                                                                                                                                                                                                                                                                                                                                                                                    
   return jsonb_build_object(                                                                                                                                                                                                                                                                                                                                                                                                       
     'ok', true,                                                                                                                                                                                                                                                                                                                                                                                                                    
     'source', 'mapped_direct_join_with_hpp',                                                                                                                                                                                                                                                                                                                                                                                       
     'rows', v_rows,                                                                                                                                                                                                                                                                                                                                                                                                                
     'total', v_total,                                                                                                                                                                                                                                                                                                                                                                                                              
     'page', v_page,                                                                                                                                                                                                                                                                                                                                                                                                                
     'page_size', v_page_size,                                                                                                                                                                                                                                                                                                                                                                                                      
     'total_pages', ceil(v_total::numeric / v_page_size::numeric),                                                                                                                                                                                                                                                                                                                                                                  
     'total_count', v_total,                                                                                                                                                                                                                                                                                                                                                                                                        
     'summary_source', 'marketplace_order_items'                                                                                                                                                                                                                                                                                                                                                                                    
   );                                                                                                                                                                                                                                                                                                                                                                                                                               
 end;                                                                                                                                                                                                                                                                                                                                                                                                                               
 $function$                                                                                                                                                                                                                                                                                                                                                                                                                         


-- ==========================================
-- PATCH: finance_sku_order_line_details
-- ==========================================

CREATE OR REPLACE FUNCTION public.finance_sku_order_line_details(
  p_start date DEFAULT NULL::date,
  p_end date DEFAULT NULL::date,
  p_marketplace text DEFAULT NULL::text,
  p_account_id uuid DEFAULT NULL::uuid,
  p_marketplace_sku text DEFAULT NULL::text,
  p_local_sku text DEFAULT NULL::text,
  p_search text DEFAULT NULL::text,
  p_payout_filter text DEFAULT 'all'::text,
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 25
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '25s'
 AS $function$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_start date := coalesce(p_start, date_trunc('month', now() at time zone 'Asia/Jakarta')::date);
  v_end date := coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date);
  v_marketplace text := nullif(lower(trim(coalesce(p_marketplace,''))), '');
  v_filter text := lower(trim(coalesce(p_payout_filter,'all')));
  v_local_sku text := lower(trim(coalesce(p_local_sku,'')));
  v_page integer := greatest(1, coalesce(p_page, 1));
  v_page_size integer := least(100, greatest(1, coalesce(p_page_size, 25)));
  v_offset integer;
  v_is_unmapped boolean := false;
  v_rows jsonb;
  v_total integer;
begin
  v_offset := (v_page - 1) * v_page_size;

  if v_marketplace in ('all','semua','_all','*','-','semua platform') then
    v_marketplace := null;
  end if;

  if v_filter in ('','all','semua','-') then
    v_filter := 'all';
  elsif v_filter in ('settled','released','release','payout','paid','sudah payout') then
    v_filter := 'paid';
  elsif v_filter in ('pending','unpaid','belum payout','no payout','missing payout') then
    v_filter := 'unpaid';
  end if;

  -- Detect UI "unmapped" label -> search for null local_sku in DB
  if v_local_sku in ('unmapped','not_mapped','tidak_dipetakan','belum dipetakan','belum_dipetakan') then
    v_is_unmapped := true;
    v_local_sku := '';
  end if;

  -- Fast path for unmapped: query marketplace_order_items directly
  if v_is_unmapped then
    with base as (
      select
        o.tenant_id,
        o.marketplace,
        o.order_id,
        o.order_sn,
        o.marketplace_order_id,
        coalesce(nullif(o.order_id::text,''), nullif(o.order_sn,''), o.marketplace_order_id::text) as order_key,
        o.order_created_at,
        o.order_status,
        o.marketplace_account_id,
        oi.marketplace_order_item_id,
        oi.marketplace_sku,
        oi.marketplace_seller_sku,
        oi.seller_sku,
        null::text as local_sku,
        oi.marketplace_product_name,
        oi.product_name,
        oi.marketplace_variant_name,
        oi.variant_name,
        greatest(1, coalesce(nullif(oi.quantity,0), nullif(oi.qty,0), 1))::integer as qty,
        coalesce(oi.gross_amount, 0)::numeric as gross_amount,
        coalesce(oi.unit_gross_amount, 0)::numeric as unit_price,
        oi.marketplace_product_id,
        oi.marketplace_sku_id,
        oi.marketplace_order_id
      from public.marketplace_order_items oi
      join public.marketplace_orders o
        on o.marketplace_order_id = oi.marketplace_order_id
        and o.tenant_id = oi.tenant_id
      where oi.tenant_id = v_tenant_id
        and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date >= v_start
        and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date <= v_end
        and (p_account_id is null or o.marketplace_account_id = p_account_id)
        and (
          v_marketplace is null
          or public._finance_marketplace_norm_20260624(o.marketplace)
             = public._finance_marketplace_norm_20260624(v_marketplace)
        )
        -- Exclude cancelled/unpaid/batal/failed/refunded orders
        and not (lower(coalesce(o.order_status, '')) ~ '(cancel|canceled|cancelled|batal|return|returned|refund|refunded|unpaid|failed|reject|in_cancel)')
        and not (lower(coalesce(o.payment_status, '')) ~ '(unpaid|failed|cancel|canceled|cancelled|refund|refunded)')
        -- Exclude UUID fake orders
        and not (o.order_sn ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        and not (coalesce(o.order_id, '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        -- unmapped: local_sku is null/empty on the item
        and coalesce(nullif(trim(oi.local_sku),''), nullif(trim(oi.mapped_local_sku),'')) is null
        -- Filter by p_marketplace_sku and p_search in unmapped path
        and (
          p_marketplace_sku is null or p_marketplace_sku = ''
          or lower(p_marketplace_sku) in (
             lower(oi.marketplace_sku::text),
             lower(oi.marketplace_seller_sku::text),
             lower(oi.seller_sku::text),
             lower(oi.marketplace_sku_id::text),
             lower(oi.marketplace_product_id::text)
          )
        )
        and (
          p_search is null or p_search = ''
          or o.order_id::text ilike '%' || p_search || '%'
          or coalesce(oi.marketplace_product_name, oi.product_name, '') ilike '%' || p_search || '%'
        )
    ),
    unmapped_base as (
      select b.*
      from base b
      left join lateral (
        select m.local_sku
        from public.marketplace_sku_maps m
        where m.tenant_id = b.tenant_id
          and m.marketplace_account_id = b.marketplace_account_id
          and m.marketplace_product_id = b.marketplace_product_id
          and m.marketplace_sku_id = b.marketplace_sku_id
          and coalesce(m.status, 'active') = 'active'
        limit 1
      ) m on true
      where m.local_sku is null
    ),
    with_payout as (
      select
        u.*,
        coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)::numeric as order_payout,
        (fr.finance_report_id is not null) as finance_report_exists,
        (coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0) > 0) as positive_payout_exists,
        (fr.finance_report_id is not null and (coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0) <> 0 or upper(coalesce(fr.settlement_status, '')) ~ '(SETTLED|PAID|RELEASE|PAYOUT_MINUS|NEGATIVE_PAYOUT)')) as has_payout
      from unmapped_base u
      left join lateral (
        select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement, fr.settlement_status
        from (
          select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement, fr.settlement_status, 1 as priority
          from public.marketplace_finance_reports fr
          where fr.tenant_id = u.tenant_id
            and fr.marketplace_account_id = u.marketplace_account_id
            and (
              fr.order_id = u.order_sn
              or fr.order_id = u.order_id::text
              or fr.order_id = u.marketplace_order_id::text
            )
            and coalesce(fr.report_type, '') <> 'statement'
          union all
          select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement, fr.settlement_status, 2 as priority
          from public.marketplace_finance_reports fr
          where fr.tenant_id = u.tenant_id
            and fr.marketplace_account_id = u.marketplace_account_id
            and fr.marketplace_order_id = u.marketplace_order_id
            and coalesce(fr.report_type, '') <> 'statement'
        ) fr
        order by priority
        limit 1
      ) fr on true
    ),
    filtered as (
      select *
      from with_payout
      where
        v_filter = 'all'
        or (v_filter = 'paid' and has_payout)
        or (v_filter = 'unpaid' and not has_payout)
    ),
    counted as (
      select count(*)::integer as total from filtered
    ),
    paged as (
      select * from filtered
      order by order_created_at desc, order_key, marketplace_order_item_id
      limit v_page_size offset v_offset
    )
    select
      coalesce(jsonb_agg(
        jsonb_build_object(
          'id', marketplace_order_item_id,
          'order_id', order_key,
          'order_sn', order_key,
          'marketplace', marketplace,
          'marketplace_name', marketplace,
          'created_at', order_created_at,
          'order_status', order_status,
          'status', order_status,
          'product_name', coalesce(marketplace_product_name, product_name, '-'),
          'variant_name', coalesce(marketplace_variant_name, variant_name, '-'),
          'marketplace_sku', coalesce(marketplace_sku, marketplace_seller_sku, seller_sku, marketplace_sku_id::text, marketplace_product_id::text, '-'),
          'local_sku', 'Unmapped',
          'qty', qty,
          'quantity', qty,
          'gross_amount', gross_amount,
          'unit_price', unit_price,
          'order_payout', order_payout,
          'has_payout', has_payout
        ) order by order_created_at desc, order_key
      ), '[]'::jsonb),
      (select coalesce(max(total),0) from counted)
    into v_rows, v_total
    from paged;

    return jsonb_build_object(
      'ok', true,
      'source', 'unmapped_direct_join',
      'rows', v_rows,
      'total', v_total,
      'page', v_page,
      'page_size', v_page_size,
      'total_pages', ceil(v_total::numeric / v_page_size::numeric),
      'total_count', v_total,
      'summary_source', 'marketplace_order_items'
    );
  end if;

  -- Default mapped logic
  -- FIX: Also join marketplace_variant_hpp_mappings to resolve local_sku for
  -- items where marketplace_order_items.local_sku / mapped_local_sku is NULL
  -- but the HPP mapping table has a local_sku for this marketplace_sku_id or
  -- marketplace_seller_sku. This ensures SKU detail popup works for cards
  -- whose live_local_sku was derived from HPP mappings in the summary function.
  with base_items as (
    select
      i.marketplace_order_item_id,
      i.marketplace_order_id,
      o.marketplace,
      o.marketplace_account_id,
      coalesce(nullif(o.order_id::text,''), nullif(o.order_sn,''), o.marketplace_order_id::text) as order_key,
      o.order_created_at,
      o.order_status,
      i.marketplace_product_name,
      i.product_name,
      i.marketplace_variant_name,
      i.variant_name,
      i.marketplace_sku,
      i.marketplace_seller_sku,
      i.seller_sku,
      coalesce(nullif(trim(i.local_sku),''), nullif(trim(i.mapped_local_sku),'')) as local_sku,
      greatest(1, coalesce(nullif(i.quantity,0), nullif(i.qty,0), 1))::integer as qty,
      coalesce(i.gross_amount, 0)::numeric as gross_amount,
      coalesce(i.unit_gross_amount, 0)::numeric as unit_price,
      i.marketplace_sku_id,
      i.marketplace_product_id
    from public.marketplace_order_items i
    join public.marketplace_orders o
      on o.marketplace_order_id = i.marketplace_order_id
      and o.tenant_id = i.tenant_id
    where i.tenant_id = v_tenant_id
      and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date >= v_start
      and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date <= v_end
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or public._finance_marketplace_norm_20260624(o.marketplace)
           = public._finance_marketplace_norm_20260624(v_marketplace)
      )
      -- Exclude cancelled/unpaid/batal/failed/refunded orders
      and not (lower(coalesce(o.order_status, '')) ~ '(cancel|canceled|cancelled|batal|return|returned|refund|refunded|unpaid|failed|reject|in_cancel)')
      and not (lower(coalesce(o.payment_status, '')) ~ '(unpaid|failed|cancel|canceled|cancelled|refund|refunded)')
      -- Exclude UUID fake orders
      and not (o.order_sn ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
      and not (coalesce(o.order_id, '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
  ),
  -- Resolve local_sku from HPP mappings for items where order_items.local_sku is NULL.
  -- This is needed because the summary function uses `live_local_sku` from HPP mappings
  -- which may not have been written back to marketplace_order_items yet.
  hpp_resolved as (
    select
      b.marketplace_order_item_id,
      -- Prefer order_items.local_sku; fall back to HPP mapping by marketplace_sku_id,
      -- then by marketplace_seller_sku. This matches the summary function's priority.
      coalesce(
        b.local_sku,
        hm_sku.local_sku,
        hm_sel.local_sku
      ) as effective_local_sku
    from base_items b
    left join lateral (
      select hm.local_sku
      from public.marketplace_variant_hpp_mappings hm
      where hm.tenant_id = v_tenant_id
        and hm.marketplace_account_id = b.marketplace_account_id
        and lower(nullif(hm.marketplace_sku_id,'')) = lower(nullif(coalesce(b.marketplace_sku, b.marketplace_seller_sku, b.seller_sku),''))
        and coalesce(hm.is_active, true) = true
        and nullif(hm.local_sku,'') is not null
      order by hm.updated_at desc nulls last
      limit 1
    ) hm_sku on true
    left join lateral (
      select hm.local_sku
      from public.marketplace_variant_hpp_mappings hm
      where hm.tenant_id = v_tenant_id
        and hm.marketplace_account_id = b.marketplace_account_id
        and lower(nullif(hm.marketplace_seller_sku,'')) = lower(nullif(coalesce(b.marketplace_seller_sku, b.marketplace_sku),''))
        and coalesce(hm.is_active, true) = true
        and nullif(hm.local_sku,'') is not null
      order by hm.updated_at desc nulls last
      limit 1
    ) hm_sel on true
  ),
  match_sku as (
    select b.*, hr.effective_local_sku
    from base_items b
    join hpp_resolved hr on hr.marketplace_order_item_id = b.marketplace_order_item_id
    where
      (
        p_marketplace_sku is null or p_marketplace_sku = ''
        or lower(p_marketplace_sku) in (
           lower(b.marketplace_sku::text),
           lower(b.marketplace_seller_sku::text),
           lower(b.seller_sku::text),
           lower(b.marketplace_sku_id::text),
           lower(b.marketplace_product_id::text)
        )
      )
      and (
        -- When v_local_sku is provided, match on effective_local_sku
        -- (which includes HPP-resolved values, not just order_items.local_sku)
        v_local_sku is null or v_local_sku = ''
        or lower(coalesce(hr.effective_local_sku,'')) = v_local_sku
      )
      and (
        p_search is null or p_search = ''
        or b.order_key ilike '%' || p_search || '%'
        or coalesce(b.marketplace_product_name, b.product_name, '') ilike '%' || p_search || '%'
      )
  ),
  with_payout as (
    select
      m.*,
      coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)::numeric as order_payout,
      (fr.finance_report_id is not null and (coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0) <> 0 or upper(coalesce(fr.settlement_status, '')) ~ '(SETTLED|PAID|RELEASE|PAYOUT_MINUS|NEGATIVE_PAYOUT)')) as has_payout
    from match_sku m
    left join lateral (
      select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement, fr.settlement_status
      from (
        select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement, fr.settlement_status, 1 as priority
        from public.marketplace_finance_reports fr
        where fr.tenant_id = v_tenant_id
          and fr.marketplace_account_id = m.marketplace_account_id
          and (
              fr.order_id = m.order_sn
              or fr.order_id = m.order_id::text
              or fr.order_id = m.marketplace_order_id::text
            )
          and coalesce(fr.report_type, '') <> 'statement'
        union all
        select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement, fr.settlement_status, 2 as priority
        from public.marketplace_finance_reports fr
        where fr.tenant_id = v_tenant_id
          and fr.marketplace_account_id = m.marketplace_account_id
          and fr.marketplace_order_id = m.marketplace_order_id
          and coalesce(fr.report_type, '') <> 'statement'
      ) fr
      order by priority
      limit 1
    ) fr on true
  ),
  filtered as (
    select *
    from with_payout
    where
      v_filter = 'all'
      or (v_filter = 'paid' and has_payout)
      or (v_filter = 'unpaid' and not has_payout)
  ),
  counted as (
    select count(*)::integer as total from filtered
  ),
  paged as (
    select * from filtered
    order by order_created_at desc, order_key, marketplace_order_item_id
    limit v_page_size offset v_offset
  )
  select
    coalesce(jsonb_agg(
      jsonb_build_object(
        'id', marketplace_order_item_id,
        'order_id', order_key,
        'order_sn', order_key,
        'marketplace', marketplace,
        'marketplace_name', marketplace,
        'created_at', order_created_at,
        'order_status', order_status,
        'status', order_status,
        'product_name', coalesce(marketplace_product_name, product_name, '-'),
        'variant_name', coalesce(marketplace_variant_name, variant_name, '-'),
        'marketplace_sku', coalesce(marketplace_sku, marketplace_seller_sku, seller_sku, marketplace_sku_id::text, marketplace_product_id::text, '-'),
        'local_sku', coalesce(effective_local_sku, local_sku, 'Unmapped'),
        'qty', qty,
        'quantity', qty,
        'gross_amount', gross_amount,
        'unit_price', unit_price,
        'order_payout', order_payout,
        'has_payout', has_payout
      ) order by order_created_at desc, order_key
    ), '[]'::jsonb),
    (select coalesce(max(total),0) from counted)
  into v_rows, v_total
  from paged;

  return jsonb_build_object(
    'ok', true,
    'source', 'mapped_direct_join_hpp_resolved',
    'rows', v_rows,
    'total', v_total,
