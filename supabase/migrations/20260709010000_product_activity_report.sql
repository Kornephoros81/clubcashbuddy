drop function if exists public.api_admin_get_product_activity_report(text, timestamp with time zone, timestamp with time zone);
drop function if exists public.admin_get_product_activity_report(timestamp with time zone, timestamp with time zone);

create or replace function public.admin_get_product_activity_report(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_payload jsonb;
begin
  perform public.assert_admin();

  if p_start is null or p_end is null then
    raise exception 'start and end are required';
  end if;

  if p_end <= p_start then
    raise exception 'end must be after start';
  end if;

  with params as (
    select
      p_start as start_at,
      p_end as end_at,
      (p_start at time zone 'Europe/Berlin')::date as start_day,
      ((p_end - interval '1 millisecond') at time zone 'Europe/Berlin')::date as end_day
  ), days as (
    select gs::date as day
    from params p
    cross join generate_series(p.start_day, p.end_day, interval '1 day') gs
  ), product_scope as (
    select p.id, p.name, p.category, p.active, p.inventoried, coalesce(p.last_purchase_price_cents, 0)::integer as last_purchase_price_cents
    from public.products p
    where p.active = true
       or exists (
         select 1 from public.transactions t
         cross join params pa
         where t.product_id = p.id
           and t.created_at >= pa.start_at
           and t.created_at < pa.end_at
       )
       or exists (
         select 1 from public.inventory_movements im
         cross join params pa
         where im.product_id = p.id
           and im.created_at >= pa.start_at
           and im.created_at < pa.end_at
       )
  ), sales as (
    select
      t.product_id,
      count(*)::integer as sold_count,
      count(*) filter (where coalesce(t.note, '') ilike '%MHD%')::integer as mhd_count,
      coalesce(sum(abs(t.amount)), 0)::integer as revenue_cents,
      coalesce(sum(coalesce(t.product_cost_snapshot_cents, 0)), 0)::integer as goods_cost_cents
    from public.transactions t
    cross join params p
    where t.product_id is not null
      and t.created_at >= p.start_at
      and t.created_at < p.end_at
      and t.amount < 0
      and coalesce(t.transaction_type, 'sale_product') = 'sale_product'
    group by t.product_id
  ), current_stock as (
    select
      l.product_id,
      coalesce(sum(l.remaining_quantity), 0)::integer as current_stock,
      coalesce(sum(l.remaining_quantity * l.unit_cost_cents), 0)::integer as current_stock_value_cents
    from public.product_purchase_lots l
    where l.source_reason <> 'sale_fallback'
      and l.remaining_quantity > 0
    group by l.product_id
  ), movement_delta as (
    select
      im.product_id,
      (im.created_at at time zone 'Europe/Berlin')::date as day,
      sum(
        case when im.to_location_id is not null then im.quantity else 0 end
        - case when im.from_location_id is not null then im.quantity else 0 end
      )::integer as delta
    from public.inventory_movements im
    cross join params p
    where im.created_at >= p.start_at
      and im.created_at < p.end_at
    group by im.product_id, (im.created_at at time zone 'Europe/Berlin')::date
  ), period_delta as (
    select product_id, coalesce(sum(delta), 0)::integer as stock_delta_period
    from movement_delta
    group by product_id
  ), opening_stock as (
    select
      ps.id as product_id,
      coalesce(sum(
        case when im.to_location_id is not null then im.quantity else 0 end
        - case when im.from_location_id is not null then im.quantity else 0 end
      ), 0)::integer as opening_stock
    from product_scope ps
    cross join params p
    left join public.inventory_movements im
      on im.product_id = ps.id
     and im.created_at < p.start_at
    group by ps.id
  ), product_days as (
    select
      ps.id as product_id,
      d.day,
      os.opening_stock,
      coalesce(md.delta, 0)::integer as delta
    from product_scope ps
    cross join days d
    join opening_stock os on os.product_id = ps.id
    left join movement_delta md on md.product_id = ps.id and md.day = d.day
  ), stock_trend as (
    select
      product_id,
      day,
      (
        opening_stock
        + sum(delta) over (partition by product_id order by day rows between unbounded preceding and current row)
      )::integer as stock
    from product_days
  ), products_json as (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'product_id', ps.id,
        'name', ps.name,
        'category', coalesce(ps.category, 'Allgemein'),
        'active', ps.active,
        'inventoried', ps.inventoried,
        'sold_count', coalesce(s.sold_count, 0),
        'mhd_count', coalesce(s.mhd_count, 0),
        'mhd_share_percent', case when coalesce(s.sold_count, 0) > 0 then round((coalesce(s.mhd_count, 0)::numeric / s.sold_count::numeric) * 100, 1) else 0 end,
        'revenue_cents', coalesce(s.revenue_cents, 0),
        'goods_cost_cents', coalesce(s.goods_cost_cents, 0),
        'gross_profit_cents', coalesce(s.revenue_cents, 0) - coalesce(s.goods_cost_cents, 0),
        'current_stock', coalesce(cs.current_stock, 0),
        'current_stock_value_cents', coalesce(cs.current_stock_value_cents, 0),
        'stock_delta_period', coalesce(pd.stock_delta_period, 0),
        'last_purchase_price_cents', ps.last_purchase_price_cents
      ) order by coalesce(s.sold_count, 0) desc, ps.name asc
    ), '[]'::jsonb) as data
    from product_scope ps
    left join sales s on s.product_id = ps.id
    left join current_stock cs on cs.product_id = ps.id
    left join period_delta pd on pd.product_id = ps.id
  ), stock_trend_json as (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'product_id', st.product_id,
        'day', st.day,
        'stock', st.stock
      ) order by st.day asc, st.product_id
    ), '[]'::jsonb) as data
    from stock_trend st
  ), metrics as (
    select
      coalesce(sum(s.sold_count), 0)::integer as total_sold_count,
      coalesce(sum(s.mhd_count), 0)::integer as total_mhd_count,
      coalesce(sum(s.revenue_cents), 0)::integer as total_revenue_cents,
      coalesce(sum(s.goods_cost_cents), 0)::integer as total_goods_cost_cents,
      coalesce(sum(s.revenue_cents) - sum(s.goods_cost_cents), 0)::integer as total_gross_profit_cents,
      count(*) filter (where coalesce(s.sold_count, 0) > 0)::integer as sold_products_count,
      coalesce(sum(cs.current_stock), 0)::integer as current_stock_units,
      coalesce(sum(cs.current_stock_value_cents), 0)::integer as current_stock_value_cents
    from product_scope ps
    left join sales s on s.product_id = ps.id
    left join current_stock cs on cs.product_id = ps.id
  )
  select jsonb_build_object(
    'metrics', jsonb_build_object(
      'totalSoldCount', m.total_sold_count,
      'totalMhdCount', m.total_mhd_count,
      'mhdSharePercent', case when m.total_sold_count > 0 then round((m.total_mhd_count::numeric / m.total_sold_count::numeric) * 100, 1) else 0 end,
      'totalRevenueCents', m.total_revenue_cents,
      'totalGoodsCostCents', m.total_goods_cost_cents,
      'totalGrossProfitCents', m.total_gross_profit_cents,
      'grossMarginPercent', case when m.total_revenue_cents > 0 then round((m.total_gross_profit_cents::numeric / m.total_revenue_cents::numeric) * 100, 1) else 0 end,
      'soldProductsCount', m.sold_products_count,
      'currentStockUnits', m.current_stock_units,
      'currentStockValueCents', m.current_stock_value_cents
    ),
    'products', pj.data,
    'stockTrend', stj.data
  )
  into v_payload
  from metrics m
  cross join products_json pj
  cross join stock_trend_json stj;

  return coalesce(v_payload, jsonb_build_object('metrics', jsonb_build_object(), 'products', '[]'::jsonb, 'stockTrend', '[]'::jsonb));
end;
$function$;

create or replace function public.api_admin_get_product_activity_report(
  p_token text,
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.app_apply_session(p_token);
  return public.admin_get_product_activity_report(p_start, p_end);
end;
$function$;

revoke all on function public.admin_get_product_activity_report(timestamp with time zone, timestamp with time zone) from public;
revoke all on function public.api_admin_get_product_activity_report(text, timestamp with time zone, timestamp with time zone) from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.admin_get_product_activity_report(timestamp with time zone, timestamp with time zone) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.api_admin_get_product_activity_report(text, timestamp with time zone, timestamp with time zone) to service_role';
  end if;
end $$;