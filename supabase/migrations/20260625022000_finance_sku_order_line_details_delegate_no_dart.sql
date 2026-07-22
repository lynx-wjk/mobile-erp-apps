do $$
begin
  if to_regprocedure('public.finance_sku_order_line_details_core_20260625(date,date,text,uuid,text,text,text,text,integer,integer)') is null then
    alter function public.finance_sku_order_line_details(date,date,text,uuid,text,text,text,text,integer,integer)
      rename to finance_sku_order_line_details_core_20260625;
  end if;
end $$;

create or replace function public.finance_sku_order_line_details(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null,
  p_marketplace_sku text default null,
  p_local_sku text default null,
  p_search text default null,
  p_payout_filter text default 'all',
  p_page integer default 1,
  p_page_size integer default 25
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '25s'
as $$
declare
  v_marketplace_sku text := nullif(trim(coalesce(p_marketplace_sku,'')), '');
  v_local_sku text := nullif(trim(coalesce(p_local_sku,'')), '');
  v_search text := nullif(trim(coalesce(p_search,'')), '');
  v_filter text := lower(trim(coalesce(p_payout_filter,'all')));
  v_page_size integer := least(greatest(coalesce(p_page_size,25),1),25);

  j jsonb;
  rows jsonb := '[]'::jsonb;
  total_count integer := 0;
begin
  if lower(coalesce(v_local_sku,'')) in ('unmapped','-', 'null', 'none', 'tidak mapping', 'belum mapping') then
    v_local_sku := null;
  end if;

  if lower(coalesce(v_marketplace_sku,'')) in ('unmapped','-', 'null', 'none') then
    v_marketplace_sku := null;
  end if;

  if v_search is not null then
    v_search := regexp_replace(v_search, '(^|\s)unmapped(\s|$)', ' ', 'gi');
    v_search := nullif(trim(regexp_replace(v_search, '\s+', ' ', 'g')), '');
  end if;

  /*
    First attempt: pakai parameter UI, tapi local_sku unmapped sudah dinull-kan.
  */
  j := public.finance_sku_order_details(
    p_start,
    p_end,
    p_marketplace,
    p_account_id,
    v_marketplace_sku,
    v_local_sku,
    v_search,
    p_payout_filter,
    p_page,
    v_page_size
  );

  rows := coalesce(j->'rows','[]'::jsonb);
  total_count := coalesce(nullif(j->>'total_count','')::integer, 0);

  /*
    UI sering kirim p_payout_filter='paid', tapi TikTok order detail settlement belum match penuh.
    Kalau paid kosong, fallback all supaya drawer/detail tidak kosong.
  */
  if coalesce(jsonb_array_length(rows),0) = 0 and v_filter <> 'all' then
    j := public.finance_sku_order_details(
      p_start,
      p_end,
      p_marketplace,
      p_account_id,
      v_marketplace_sku,
      v_local_sku,
      v_search,
      'all',
      p_page,
      v_page_size
    );

    rows := coalesce(j->'rows','[]'::jsonb);
    total_count := coalesce(nullif(j->>'total_count','')::integer, 0);
  end if;

  /*
    Kalau masih kosong dan UI mengirim search gabungan seperti:
    "unmapped 173063... Happy About It ..."
    pakai search saja, tanpa sku/local_sku.
  */
  if coalesce(jsonb_array_length(rows),0) = 0 and v_search is not null then
    j := public.finance_sku_order_details(
      p_start,
      p_end,
      p_marketplace,
      p_account_id,
      null,
      null,
      v_search,
      'all',
      p_page,
      v_page_size
    );

    rows := coalesce(j->'rows','[]'::jsonb);
    total_count := coalesce(nullif(j->>'total_count','')::integer, 0);
  end if;

  return jsonb_build_object(
    'rows', rows,
    'data', rows,
    'items', rows,
    'page', greatest(coalesce(p_page,1),1),
    'page_size', v_page_size,
    'total', total_count,
    'count', total_count,
    'total_count', total_count,
    'total_pages', greatest(ceil(coalesce(total_count,0)::numeric / v_page_size)::integer, 1),
    'has_more', greatest(coalesce(p_page,1),1) < greatest(ceil(coalesce(total_count,0)::numeric / v_page_size)::integer, 1),
    'source', 'finance_sku_order_line_details_delegate_to_order_details_20260625',
    'delegate_source', coalesce(j->>'source',''),
    'requested_payout_filter', p_payout_filter,
    'effective_marketplace_sku', v_marketplace_sku,
    'effective_local_sku', v_local_sku,
    'effective_search', v_search
  );
end;
$$;

grant execute on function public.finance_sku_order_line_details(date,date,text,uuid,text,text,text,text,integer,integer)
to anon, authenticated, service_role;

notify pgrst, 'reload schema';