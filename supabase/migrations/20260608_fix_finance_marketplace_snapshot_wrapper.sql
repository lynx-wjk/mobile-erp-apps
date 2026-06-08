begin;

do $$
begin
  if to_regprocedure('public.finance_customer_dashboard_snapshot_v24_6_82o_b20260608(date,date,text,uuid)') is null then
    alter function public.finance_customer_dashboard_snapshot_v24_6_82o(date,date,text,uuid)
    rename to finance_customer_dashboard_snapshot_v24_6_82o_b20260608;
  end if;
end $$;

create or replace function public.finance_customer_dashboard_snapshot_v24_6_82o(
  p_start date default null::date,
  p_end date default null::date,
  p_marketplace text default null::text,
  p_account_id uuid default null::uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  j jsonb;
  s jsonb;
  marketplace_count int;
  should_patch_marketplace boolean;
  v_payout numeric;
  v_hpp numeric;
  v_profit numeric;
  v_margin numeric;
  v_expense numeric;
  v_minus_payout numeric;
  v_negative_count numeric;
  v_abnormal_count numeric;
  v_pending_hpp numeric;
  fixed_marketplaces jsonb;
  fixed_by_marketplace jsonb;
begin
  j := public.finance_customer_dashboard_snapshot_v24_6_82o_b20260608(
    p_start,
    p_end,
    p_marketplace,
    p_account_id
  );

  if j is null or coalesce((j->>'ok')::boolean, false) is false then
    return j;
  end if;

  s := coalesce(j->'summary', '{}'::jsonb);

  marketplace_count := coalesce(nullif(s->>'marketplace_count', '')::int, 0);

  should_patch_marketplace :=
    marketplace_count <= 1
    or jsonb_array_length(coalesce(j->'marketplaces', '[]'::jsonb)) = 1
    or (
      p_marketplace is not null
      and lower(coalesce(p_marketplace, 'all')) <> 'all'
    );

  if not should_patch_marketplace then
    return j;
  end if;

  v_payout := coalesce(nullif(s->>'payout_total', '')::numeric, 0);
  v_hpp := coalesce(nullif(s->>'hpp_total', '')::numeric, 0);
  v_profit := coalesce(nullif(s->>'net_profit', '')::numeric, 0);
  v_margin := coalesce(nullif(s->>'margin_percent', '')::numeric, 0);
  v_expense := coalesce(nullif(s->>'expense_total', '')::numeric, 0);
  v_minus_payout := coalesce(
    nullif(s->>'payout_minus_total', '')::numeric,
    coalesce(nullif(s->>'minus_payout_total', '')::numeric, 0)
  );
  v_negative_count := coalesce(nullif(s->>'negative_payout_count', '')::numeric, 0);
  v_abnormal_count := coalesce(nullif(s->>'abnormal_count', '')::numeric, 0);
  v_pending_hpp := coalesce(
    nullif(s->>'pending_hpp_total', '')::numeric,
    coalesce(nullif(s->>'estimated_unpaid_hpp_total', '')::numeric, 0)
  );

  fixed_marketplaces := (
    select coalesce(
      jsonb_agg(
        case
          when coalesce(nullif(elem->>'payout_total', '')::numeric, 0) = 0
               and v_payout <> 0
          then elem || jsonb_build_object(
            'payout_total', v_payout,
            'payout_amount', v_payout,
            'received_amount', v_payout,
            'net_received', v_payout,
            'net_settlement', v_payout,

            'hpp_total', v_hpp,
            'total_hpp', v_hpp,
            'paid_hpp_total', v_hpp,
            'settled_hpp_total', v_hpp,

            'net_profit', v_profit,
            'profit', v_profit,
            'margin_percent', v_margin,

            'expense_total', v_expense,
            'operational_cost_total', v_expense,

            'minus_payout_total', v_minus_payout,
            'payout_minus_total', v_minus_payout,
            'negative_payout_total', v_minus_payout,
            'negative_payout_count', v_negative_count,
            'abnormal_count', v_abnormal_count,

            'pending_hpp_total', v_pending_hpp,
            'estimated_unpaid_hpp_total', v_pending_hpp
          )
          else elem
        end
        order by ord
      ),
      '[]'::jsonb
    )
    from jsonb_array_elements(coalesce(j->'marketplaces', '[]'::jsonb)) with ordinality as t(elem, ord)
  );

  fixed_by_marketplace := (
    select coalesce(
      jsonb_agg(
        case
          when coalesce(nullif(elem->>'payout_total', '')::numeric, 0) = 0
               and v_payout <> 0
          then elem || jsonb_build_object(
            'payout_total', v_payout,
            'payout_amount', v_payout,
            'received_amount', v_payout,
            'net_received', v_payout,
            'net_settlement', v_payout,

            'hpp_total', v_hpp,
            'total_hpp', v_hpp,
            'paid_hpp_total', v_hpp,
            'settled_hpp_total', v_hpp,

            'net_profit', v_profit,
            'profit', v_profit,
            'margin_percent', v_margin,

            'expense_total', v_expense,
            'operational_cost_total', v_expense,

            'minus_payout_total', v_minus_payout,
            'payout_minus_total', v_minus_payout,
            'negative_payout_total', v_minus_payout,
            'negative_payout_count', v_negative_count,
            'abnormal_count', v_abnormal_count,

            'pending_hpp_total', v_pending_hpp,
            'estimated_unpaid_hpp_total', v_pending_hpp
          )
          else elem
        end
        order by ord
      ),
      '[]'::jsonb
    )
    from jsonb_array_elements(coalesce(j->'by_marketplace', '[]'::jsonb)) with ordinality as t(elem, ord)
  );

  j := jsonb_set(j, '{marketplaces}', fixed_marketplaces, true);
  j := jsonb_set(j, '{by_marketplace}', fixed_by_marketplace, true);

  return j;
end;
$$;

commit;
