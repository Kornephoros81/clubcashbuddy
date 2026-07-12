drop function if exists public.api_admin_get_order_suggestions(text, integer, numeric, numeric);
drop function if exists public.api_admin_get_order_suggestions(text, integer, numeric);
drop function if exists public.admin_get_order_suggestions(integer, numeric, numeric);
drop function if exists public.admin_get_order_suggestions(integer, numeric);

create or replace function public.admin_get_order_suggestions(
  p_horizon_days integer default 60,
  p_safety_percent numeric default 20
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_horizon_days integer := greatest(1, least(90, coalesce(p_horizon_days, 60)));
  v_safety_percent numeric := greatest(0, least(100, coalesce(p_safety_percent, 20)));
  v_payload jsonb;
begin
  perform public.assert_admin();

  with months as (
    select gs.month_start::date as month_start
    from generate_series(
      date_trunc('month', (now() at time zone 'Europe/Berlin') - interval '11 months'),
      date_trunc('month', now() at time zone 'Europe/Berlin'),
      interval '1 month'
    ) as gs(month_start)
  ), product_scope as (
    select
      p.id,
      p.name,
      coalesce(p.category, 'Allgemein') as category,
      greatest(1, coalesce(p.package_size, 1))::integer as package_size,
      greatest(0, coalesce(p.last_purchase_price_cents, 0))::integer as last_purchase_price_cents,
      (p.created_at at time zone 'Europe/Berlin') as created_local_at,
      greatest(0, floor(extract(epoch from (now() - p.created_at)) / 86400)::integer) as product_age_days,
      greatest(1, least(28, floor(extract(epoch from (now() - p.created_at)) / 86400)::integer)) as demand_age_days
    from public.products p
    where p.active = true
      and p.inventoried = true
  ), monthly_activity as (
    select
      date_trunc('month', t.created_at at time zone 'Europe/Berlin')::date as month_start,
      count(distinct t.member_id)::integer as active_members
    from public.transactions t
    where t.created_at >= now() - interval '12 months'
      and t.amount < 0
      and t.member_id is not null
      and coalesce(t.transaction_type, 'sale_product') in ('sale_product', 'sale_free_amount')
    group by date_trunc('month', t.created_at at time zone 'Europe/Berlin')::date
  ), active_now as (
    select count(distinct t.member_id)::integer as active_members_28d
    from public.transactions t
    where t.created_at >= now() - interval '28 days'
      and t.amount < 0
      and t.member_id is not null
      and coalesce(t.transaction_type, 'sale_product') in ('sale_product', 'sale_free_amount')
  ), product_month_sales as (
    select
      t.product_id,
      date_trunc('month', t.created_at at time zone 'Europe/Berlin')::date as month_start,
      count(*)::integer as sold_regular
    from public.transactions t
    where t.product_id is not null
      and t.created_at >= now() - interval '12 months'
      and t.amount < 0
      and coalesce(t.transaction_type, 'sale_product') = 'sale_product'
      and coalesce(t.sale_kind, 'regular') = 'regular'
    group by t.product_id, date_trunc('month', t.created_at at time zone 'Europe/Berlin')::date
  ), model_inputs as (
    select
      ps.id as product_id,
      coalesce(sum(coalesce(pms.sold_regular, 0)), 0)::integer as model_sold_regular,
      coalesce(sum(coalesce(ma.active_members, 0)), 0)::integer as model_active_members,
      case
        when coalesce(sum(coalesce(ma.active_members, 0)), 0) > 0
          then coalesce(sum(coalesce(pms.sold_regular, 0)), 0)::numeric
            / nullif(sum(coalesce(ma.active_members, 0))::numeric, 0)
        else null
      end as per_member_rate_raw
    from product_scope ps
    cross join months mo
    left join monthly_activity ma on ma.month_start = mo.month_start
    left join product_month_sales pms on pms.product_id = ps.id and pms.month_start = mo.month_start
    where (mo.month_start + interval '1 month') > ps.created_local_at
    group by ps.id
  ), sales as (
    select
      t.product_id,
      count(*) filter (
        where t.created_at >= now() - interval '14 days'
          and coalesce(t.sale_kind, 'regular') = 'regular'
      )::integer as sold_14,
      count(*) filter (
        where t.created_at >= now() - interval '30 days'
          and coalesce(t.sale_kind, 'regular') = 'regular'
      )::integer as sold_30,
      count(*) filter (
        where coalesce(t.sale_kind, 'regular') = 'regular'
      )::integer as sold_90,
      count(*) filter (
        where t.created_at >= now() - interval '28 days'
          and coalesce(t.sale_kind, 'regular') = 'regular'
      )::integer as sold_28_regular,
      count(*)::integer as sold_90_total,
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
      ps.package_size,
      ps.last_purchase_price_cents,
      ps.product_age_days,
      ps.demand_age_days,
      coalesce(cs.current_stock, 0)::integer as current_stock,
      coalesce(s.sold_14, 0)::integer as sold_14,
      coalesce(s.sold_30, 0)::integer as sold_30,
      coalesce(s.sold_90, 0)::integer as sold_90,
      coalesce(s.sold_28_regular, 0)::integer as sold_28_regular,
      coalesce(s.sold_90_total, 0)::integer as sold_90_total,
      coalesce(s.mhd_90, 0)::integer as mhd_90,
      coalesce(mi.model_active_members, 0)::integer as model_active_members,
      mi.per_member_rate_raw,
      case
        when ps.product_age_days >= 60
          and coalesce(mi.model_active_members, 0) > 0
          and mi.per_member_rate_raw is not null
          then round(mi.per_member_rate_raw, 3)
        else null
      end as per_member_rate,
      round((coalesce(s.sold_28_regular, 0)::numeric / ps.demand_age_days::numeric), 3) as demand_recent,
      round((coalesce(mi.per_member_rate_raw, 0) * coalesce(an.active_members_28d, 0)::numeric / 30.44), 3) as demand_model,
      coalesce(an.active_members_28d, 0)::integer as active_members_28d,
      case
        when coalesce(s.sold_90_total, 0) > 0
          then round((coalesce(s.mhd_90, 0)::numeric / s.sold_90_total::numeric) * 100, 1)
        else 0
      end as mhd_share_percent
    from product_scope ps
    cross join active_now an
    left join sales s on s.product_id = ps.id
    left join model_inputs mi on mi.product_id = ps.id
    left join current_stock cs on cs.product_id = ps.id
  ), demand_selected as (
    select
      c.*,
      case
        when c.product_age_days >= 60
          and c.model_active_members > 0
          and c.per_member_rate_raw is not null
          and c.demand_model >= c.demand_recent
          then 'model'
        when c.product_age_days >= 60
          and c.model_active_members > 0
          and c.per_member_rate_raw is not null
          then 'recent'
        else 'fallback'
      end as demand_source,
      case
        when c.product_age_days >= 60
          and c.model_active_members > 0
          and c.per_member_rate_raw is not null
          then greatest(c.demand_model, c.demand_recent)
        else c.demand_recent
      end as daily_demand
    from calculated c
  ), enriched as (
    select
      d.*,
      case
        when d.daily_demand > 0 then round(d.current_stock::numeric / d.daily_demand, 1)
        else null
      end as reach_days,
      greatest(0, ceil(d.daily_demand * v_horizon_days * (1 + (v_safety_percent / 100)))::integer) as target_stock,
      case
        when d.daily_demand = 0 then 'no_demand'
        when d.current_stock <= 0 then 'out_of_stock'
        when (d.current_stock::numeric / d.daily_demand) < (v_horizon_days::numeric / 2) then 'low'
        else 'ok'
      end as stock_status,
      case
        when d.sold_90 = 0 then 'stable'
        when (d.sold_14::numeric / 14) > (d.sold_90::numeric / 90) * 1.25 then 'rising'
        when (d.sold_14::numeric / 14) < (d.sold_90::numeric / 90) * 0.75 then 'falling'
        else 'stable'
      end as trend
    from demand_selected d
  ), suggested as (
    select
      e.*,
      case
        when e.target_stock <= e.current_stock then 0
        else (ceil((e.target_stock - e.current_stock)::numeric / e.package_size) * e.package_size)::integer
      end as suggested_units
    from enriched e
  ), final_rows as (
    select
      s.*,
      case
        when s.package_size > 1 then (s.suggested_units / s.package_size)::integer
        else s.suggested_units
      end as suggested_packages,
      (s.suggested_units * s.last_purchase_price_cents)::integer as estimated_cost_cents,
      case
        when s.demand_source = 'fallback' and (
          case
            when s.sold_90_total = 0 then 'niedrig'
            when s.sold_90_total < 10 then 'niedrig'
            when s.mhd_share_percent >= 30 then 'mittel'
            when s.trend <> 'stable' then 'mittel'
            else 'hoch'
          end
        ) = 'hoch' then 'mittel'
        else case
          when s.sold_90_total = 0 then 'niedrig'
          when s.sold_90_total < 10 then 'niedrig'
          when s.mhd_share_percent >= 30 then 'mittel'
          when s.trend <> 'stable' then 'mittel'
          else 'hoch'
        end
      end as confidence,
      array_remove(array[
        case when s.sold_90_total = 0 then 'Keine Verkäufe in den letzten 90 Tagen' end,
        case when s.sold_90_total > 0 and s.sold_90_total < 10 then 'Wenig Datenbasis' end,
        case when s.stock_status = 'out_of_stock' then 'Aktuell kein Bestand' end,
        case when s.stock_status = 'low' then 'Reichweite unter halbem Bestellhorizont' end,
        case when s.mhd_share_percent >= 30 then 'Hoher MHD-Anteil' end,
        case when s.demand_source = 'fallback' then 'Zu wenig Historie – 28-Tage-Durchschnitt verwendet' end,
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
        'mhd_90', mhd_90,
        'mhd_share_percent', mhd_share_percent,
        'daily_demand', daily_demand,
        'per_member_rate', per_member_rate,
        'demand_source', demand_source,
        'reach_days', reach_days,
        'target_stock', target_stock,
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
      coalesce(sum(estimated_cost_cents), 0)::integer as total_estimated_cost_cents,
      coalesce(max(active_members_28d), 0)::integer as active_members_28d
    from final_rows
  )
  select jsonb_build_object(
    'parameters', jsonb_build_object(
      'horizonDays', v_horizon_days,
      'safetyPercent', v_safety_percent
    ),
    'metrics', jsonb_build_object(
      'productCount', m.product_count,
      'suggestedProductsCount', m.suggested_products_count,
      'outOfStockCount', m.out_of_stock_count,
      'lowStockCount', m.low_stock_count,
      'totalSuggestedUnits', m.total_suggested_units,
      'totalEstimatedCostCents', m.total_estimated_cost_cents,
      'activeMembers28d', m.active_members_28d
    ),
    'products', pj.data
  )
  into v_payload
  from metrics m
  cross join products_json pj;

  return coalesce(v_payload, jsonb_build_object(
    'parameters', jsonb_build_object('horizonDays', v_horizon_days, 'safetyPercent', v_safety_percent),
    'metrics', jsonb_build_object('activeMembers28d', 0),
    'products', '[]'::jsonb
  ));
end;
$function$;

create or replace function public.api_admin_get_order_suggestions(
  p_token text,
  p_horizon_days integer default 60,
  p_safety_percent numeric default 20
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.app_apply_session(p_token);
  return public.admin_get_order_suggestions(p_horizon_days, p_safety_percent);
end;
$function$;

revoke all on function public.admin_get_order_suggestions(integer, numeric) from public;
revoke all on function public.api_admin_get_order_suggestions(text, integer, numeric) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.admin_get_order_suggestions(integer, numeric) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.api_admin_get_order_suggestions(text, integer, numeric) to service_role';
  end if;
end $$;

notify pgrst, 'reload schema';
