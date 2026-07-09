drop function if exists public.api_admin_get_order_suggestions(text, integer, numeric, numeric);
drop function if exists public.admin_get_order_suggestions(integer, numeric, numeric);

create or replace function public.admin_get_order_suggestions(
  p_horizon_days integer default 14,
  p_safety_percent numeric default 20,
  p_min_reach_days numeric default 7
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_horizon_days integer := greatest(1, least(60, coalesce(p_horizon_days, 14)));
  v_safety_percent numeric := greatest(0, least(100, coalesce(p_safety_percent, 20)));
  v_min_reach_days numeric := greatest(0, least(60, coalesce(p_min_reach_days, 7)));
  v_payload jsonb;
begin
  perform public.assert_admin();

  with product_scope as (
    select
      p.id,
      p.name,
      coalesce(p.category, 'Allgemein') as category,
      coalesce(p.package_size, 1)::integer as package_size,
      greatest(0, coalesce(p.last_purchase_price_cents, 0))::integer as last_purchase_price_cents
    from public.products p
    where p.active = true
      and p.inventoried = true
  ), sales as (
    select
      t.product_id,
      count(*) filter (where t.created_at >= now() - interval '14 days')::integer as sold_14,
      count(*) filter (where t.created_at >= now() - interval '30 days')::integer as sold_30,
      count(*)::integer as sold_90,
      count(*) filter (where t.created_at >= now() - interval '14 days' and coalesce(t.sale_kind, 'regular') = 'mhd')::integer as mhd_14,
      count(*) filter (where t.created_at >= now() - interval '30 days' and coalesce(t.sale_kind, 'regular') = 'mhd')::integer as mhd_30,
      count(*) filter (where coalesce(t.sale_kind, 'regular') = 'mhd')::integer as mhd_90
    from public.transactions t
    where t.product_id is not null
      and t.created_at >= now() - interval '90 days'
      and t.amount < 0
      and coalesce(t.transaction_type, 'sale_product') = 'sale_product'
    group by t.product_id
  ), current_stock as (
    select
      l.product_id,
      coalesce(sum(l.remaining_quantity), 0)::integer as current_stock
    from public.product_purchase_lots l
    where l.source_reason <> 'sale_fallback'
      and l.remaining_quantity > 0
    group by l.product_id
  ), calculated as (
    select
      ps.id as product_id,
      ps.name,
      ps.category,
      greatest(1, coalesce(ps.package_size, 1))::integer as package_size,
      ps.last_purchase_price_cents,
      coalesce(cs.current_stock, 0)::integer as current_stock,
      coalesce(s.sold_14, 0)::integer as sold_14,
      coalesce(s.sold_30, 0)::integer as sold_30,
      coalesce(s.sold_90, 0)::integer as sold_90,
      coalesce(s.mhd_14, 0)::integer as mhd_14,
      coalesce(s.mhd_30, 0)::integer as mhd_30,
      coalesce(s.mhd_90, 0)::integer as mhd_90,
      round((
        (coalesce(s.sold_14, 0)::numeric / 14) * 0.5
        + (coalesce(s.sold_30, 0)::numeric / 30) * 0.3
        + (coalesce(s.sold_90, 0)::numeric / 90) * 0.2
      ), 3) as daily_demand,
      case
        when coalesce(s.sold_90, 0) > 0
          then round((coalesce(s.mhd_90, 0)::numeric / s.sold_90::numeric) * 100, 1)
        else 0
      end as mhd_share_percent
    from product_scope ps
    left join sales s on s.product_id = ps.id
    left join current_stock cs on cs.product_id = ps.id
  ), enriched as (
    select
      c.*,
      case
        when c.daily_demand > 0 then round(c.current_stock::numeric / c.daily_demand, 1)
        else null
      end as reach_days,
      greatest(0, ceil(c.daily_demand * v_horizon_days * (1 + (v_safety_percent / 100)))::integer) as target_stock,
      case
        when c.daily_demand = 0 then 'no_demand'
        when c.current_stock <= 0 then 'out_of_stock'
        when (c.current_stock::numeric / c.daily_demand) <= v_min_reach_days then 'low'
        else 'ok'
      end as stock_status,
      case
        when c.sold_90 = 0 and c.sold_14 > 0 then 'rising'
        when c.sold_90 = 0 then 'stable'
        when (c.sold_14::numeric / 14) > (c.sold_90::numeric / 90) * 1.25 then 'rising'
        when (c.sold_14::numeric / 14) < (c.sold_90::numeric / 90) * 0.75 then 'falling'
        else 'stable'
      end as trend
    from calculated c
  ), suggested as (
    select
      e.*,
      greatest(0, e.target_stock - e.current_stock)::integer as raw_suggested_units,
      case
        when e.daily_demand <= 0 then 0
        when e.stock_status not in ('out_of_stock', 'low') then 0
        when e.target_stock <= e.current_stock then 0
        else (ceil((e.target_stock - e.current_stock)::numeric / e.package_size) * e.package_size)::integer
      end as suggested_units
    from enriched e
  ), final_rows as (
    select
      s.*,
      case
        when s.package_size > 1 and s.suggested_units > 0 then ceil(s.suggested_units::numeric / s.package_size)::integer
        else s.suggested_units
      end as suggested_packages,
      (s.suggested_units * s.last_purchase_price_cents)::integer as estimated_cost_cents,
      case
        when s.sold_90 = 0 then 'niedrig'
        when s.sold_90 < 10 then 'niedrig'
        when s.mhd_share_percent >= 30 then 'mittel'
        when s.trend <> 'stable' then 'mittel'
        else 'hoch'
      end as confidence,
      array_remove(array[
        case when s.sold_90 = 0 then 'Keine Verkäufe in den letzten 90 Tagen' end,
        case when s.sold_90 > 0 and s.sold_90 < 10 then 'Wenig Datenbasis' end,
        case when s.stock_status = 'out_of_stock' then 'Aktuell kein Bestand' end,
        case when s.stock_status = 'low' then 'Reichweite unter Grenzwert' end,
        case when s.mhd_share_percent >= 30 then 'Hoher MHD-Anteil' end,
        case when s.last_purchase_price_cents = 0 then 'Kein Einkaufspreis gepflegt' end
      ], null) as warnings
    from suggested s
  ), products_json as (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'product_id', product_id,
        'name', name,
        'category', category,
        'package_size', package_size,
        'current_stock', current_stock,
        'sold_14', sold_14,
        'sold_30', sold_30,
        'sold_90', sold_90,
        'mhd_14', mhd_14,
        'mhd_30', mhd_30,
        'mhd_90', mhd_90,
        'mhd_share_percent', mhd_share_percent,
        'daily_demand', daily_demand,
        'reach_days', reach_days,
        'target_stock', target_stock,
        'raw_suggested_units', raw_suggested_units,
        'suggested_units', suggested_units,
        'suggested_packages', suggested_packages,
        'estimated_cost_cents', estimated_cost_cents,
        'last_purchase_price_cents', last_purchase_price_cents,
        'trend', trend,
        'stock_status', stock_status,
        'confidence', confidence,
        'warnings', to_jsonb(warnings)
      )
      order by suggested_units desc, reach_days asc nulls last, sold_30 desc, name asc
    ), '[]'::jsonb) as data
    from final_rows
  ), metrics as (
    select
      count(*)::integer as product_count,
      count(*) filter (where suggested_units > 0)::integer as suggested_products_count,
      count(*) filter (where stock_status = 'out_of_stock')::integer as out_of_stock_count,
      count(*) filter (where stock_status = 'low')::integer as low_stock_count,
      coalesce(sum(suggested_units), 0)::integer as total_suggested_units,
      coalesce(sum(estimated_cost_cents), 0)::integer as total_estimated_cost_cents
    from final_rows
  )
  select jsonb_build_object(
    'parameters', jsonb_build_object(
      'horizonDays', v_horizon_days,
      'safetyPercent', v_safety_percent,
      'minReachDays', v_min_reach_days
    ),
    'metrics', jsonb_build_object(
      'productCount', m.product_count,
      'suggestedProductsCount', m.suggested_products_count,
      'outOfStockCount', m.out_of_stock_count,
      'lowStockCount', m.low_stock_count,
      'totalSuggestedUnits', m.total_suggested_units,
      'totalEstimatedCostCents', m.total_estimated_cost_cents
    ),
    'products', pj.data
  )
  into v_payload
  from metrics m
  cross join products_json pj;

  return coalesce(v_payload, jsonb_build_object(
    'parameters', jsonb_build_object('horizonDays', v_horizon_days, 'safetyPercent', v_safety_percent, 'minReachDays', v_min_reach_days),
    'metrics', jsonb_build_object(),
    'products', '[]'::jsonb
  ));
end;
$function$;

create or replace function public.api_admin_get_order_suggestions(
  p_token text,
  p_horizon_days integer default 14,
  p_safety_percent numeric default 20,
  p_min_reach_days numeric default 7
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.app_apply_session(p_token);
  return public.admin_get_order_suggestions(p_horizon_days, p_safety_percent, p_min_reach_days);
end;
$function$;

revoke all on function public.admin_get_order_suggestions(integer, numeric, numeric) from public;
revoke all on function public.api_admin_get_order_suggestions(text, integer, numeric, numeric) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.admin_get_order_suggestions(integer, numeric, numeric) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.api_admin_get_order_suggestions(text, integer, numeric, numeric) to service_role';
  end if;
end $$;
