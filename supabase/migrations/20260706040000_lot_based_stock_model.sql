create or replace function public.get_product_stock(p_product_id uuid)
returns table(
  warehouse_qty integer,
  fridge_qty integer,
  total_qty integer
)
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $function$
  select
    coalesce(sum(l.remaining_quantity), 0)::integer as warehouse_qty,
    0::integer as fridge_qty,
    coalesce(sum(l.remaining_quantity), 0)::integer as total_qty
  from public.product_purchase_lots l
  where l.product_id = p_product_id
    and l.source_reason <> 'sale_fallback'
    and l.remaining_quantity > 0;
$function$;

create or replace function public.refresh_product_stock(p_product_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_stock record;
begin
  select *
  into v_stock
  from public.get_product_stock(p_product_id);

  update public.products p
  set
    warehouse_stock = coalesce(v_stock.warehouse_qty, 0),
    fridge_stock = coalesce(v_stock.fridge_qty, 0)
  where p.id = p_product_id;
end;
$function$;

create or replace function public.refresh_product_inventory_value_from_lots(
  p_product_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_stock_qty integer;
  v_inventory_value integer;
  v_last_purchase integer;
begin
  select
    coalesce(sum(l.remaining_quantity), 0)::integer,
    coalesce(sum(l.remaining_quantity * l.unit_cost_cents), 0)::integer
  into v_stock_qty, v_inventory_value
  from public.product_purchase_lots l
  where l.product_id = p_product_id
    and l.source_reason <> 'sale_fallback'
    and l.remaining_quantity > 0;

  select l.unit_cost_cents
  into v_last_purchase
  from public.product_purchase_lots l
  where l.product_id = p_product_id
    and l.source_reason = 'purchase'
  order by l.created_at desc, l.id desc
  limit 1;

  update public.products p
  set
    warehouse_stock = greatest(0, coalesce(v_stock_qty, 0)),
    fridge_stock = 0,
    inventory_value_cents = greatest(0, coalesce(v_inventory_value, 0)),
    last_purchase_price_cents = case
      when v_last_purchase is not null then greatest(0, v_last_purchase)
      else p.last_purchase_price_cents
    end
  where p.id = p_product_id;
end;
$function$;

create or replace function public.admin_list_products()
returns table(
  id uuid,
  name text,
  price integer,
  guest_price integer,
  category text,
  active boolean,
  inventoried boolean,
  created_at timestamp with time zone,
  warehouse_stock integer,
  fridge_stock integer,
  last_restocked_at timestamp with time zone,
  last_purchase_price_cents integer,
  inventory_value_cents integer
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.assert_admin();

  return query
  select
    p.id,
    p.name,
    p.price,
    p.guest_price,
    p.category,
    p.active,
    p.inventoried,
    p.created_at,
    case when p.inventoried then coalesce(s.warehouse_qty, 0) else coalesce(p.warehouse_stock, 0) end::integer as warehouse_stock,
    case when p.inventoried then coalesce(s.fridge_qty, 0) else coalesce(p.fridge_stock, 0) end::integer as fridge_stock,
    p.last_restocked_at,
    p.last_purchase_price_cents,
    case when p.inventoried then coalesce(v.inventory_value_cents, 0) else coalesce(p.inventory_value_cents, 0) end::integer as inventory_value_cents
  from public.products p
  left join lateral public.get_product_stock(p.id) s on true
  left join lateral (
    select coalesce(sum(l.remaining_quantity * l.unit_cost_cents), 0)::integer as inventory_value_cents
    from public.product_purchase_lots l
    where l.product_id = p.id
      and l.source_reason <> 'sale_fallback'
      and l.remaining_quantity > 0
  ) v on true
  order by p.active desc, p.name asc;
end;
$function$;

create or replace function public.api_admin_list_products(p_token text)
returns table(
  id uuid,
  name text,
  price integer,
  guest_price integer,
  category text,
  active boolean,
  inventoried boolean,
  created_at timestamp with time zone,
  warehouse_stock integer,
  fridge_stock integer,
  last_restocked_at timestamp with time zone,
  last_purchase_price_cents integer,
  inventory_value_cents integer
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.app_apply_session(p_token);
  return query
  select * from public.admin_list_products();
end;
$function$;

create or replace function public.get_inventory_snapshot()
returns table(
  product_id uuid,
  name text,
  category text,
  active boolean,
  soll_warehouse_stock integer,
  soll_fridge_stock integer,
  soll_total_stock integer
)
language sql
security definer
set search_path = public, extensions, pg_temp
as $function$
  select
    p.id as product_id,
    p.name as name,
    p.category as category,
    p.active as active,
    coalesce(s.warehouse_qty, 0)::integer as soll_warehouse_stock,
    coalesce(s.fridge_qty, 0)::integer as soll_fridge_stock,
    coalesce(s.total_qty, 0)::integer as soll_total_stock
  from public.products p
  left join lateral public.get_product_stock(p.id) s on true
  where p.inventoried = true
  order by p.active desc, p.category, p.name;
$function$;

create or replace function public.get_inventory_adjustments_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  created_at timestamp with time zone,
  local_day date,
  product_id uuid,
  product_name text,
  product_category text,
  active boolean,
  location text,
  delta integer,
  adjustment_kind text,
  reason text,
  note text,
  source text
)
language sql
security definer
set search_path = public, extensions, pg_temp
as $function$
  with loc as (
    select public.get_stock_location_id('warehouse') as wh_id,
           public.get_stock_location_id('fridge') as fr_id
  ), movement_adjustments as (
    select
      im.created_at,
      (im.created_at at time zone 'Europe/Berlin')::date as local_day,
      im.product_id,
      coalesce(p.name, '[Geloeschtes Produkt]') as product_name,
      coalesce(p.category, 'Unbekannt') as product_category,
      coalesce(p.active, false) as active,
      case
        when im.to_location_id = loc.wh_id or im.from_location_id = loc.wh_id then 'warehouse'
        when im.to_location_id = loc.fr_id or im.from_location_id = loc.fr_id then 'fridge'
        else 'unknown'
      end as location,
      (
        case when im.to_location_id is not null then im.quantity else 0 end
        - case when im.from_location_id is not null then im.quantity else 0 end
      )::integer as delta,
      case
        when (
          case when im.to_location_id is not null then im.quantity else 0 end
          - case when im.from_location_id is not null then im.quantity else 0 end
        ) < 0 then 'fehlbestand'
        when (
          case when im.to_location_id is not null then im.quantity else 0 end
          - case when im.from_location_id is not null then im.quantity else 0 end
        ) > 0 then 'ueberbestand'
        else 'neutral'
      end as adjustment_kind,
      im.reason,
      im.note,
      coalesce(im.meta->>'source', 'unknown') as source
    from public.inventory_movements im
    cross join loc
    left join public.products p on p.id = im.product_id
    where im.created_at >= p_start
      and im.created_at < p_end
      and im.reason in ('count_adjustment', 'shrinkage', 'waste')
  ), open_fallback_sales as (
    select
      a.created_at,
      (a.created_at at time zone 'Europe/Berlin')::date as local_day,
      a.product_id,
      coalesce(p.name, '[Geloeschtes Produkt]') as product_name,
      coalesce(p.category, 'Unbekannt') as product_category,
      coalesce(p.active, false) as active,
      'warehouse'::text as location,
      (-a.quantity)::integer as delta,
      'fehlbestand'::text as adjustment_kind,
      'sale_fallback'::text as reason,
      coalesce(l.note, 'Verkauf ohne gedecktes Lot') as note,
      'fallback_lot'::text as source
    from public.product_lot_allocations a
    join public.product_purchase_lots l on l.id = a.purchase_lot_id
    left join public.products p on p.id = a.product_id
    where a.created_at >= p_start
      and a.created_at < p_end
      and a.reason = 'sale'
      and a.reversed_at is null
      and l.source_reason = 'sale_fallback'
  )
  select * from movement_adjustments
  union all
  select * from open_fallback_sales
  order by created_at desc;
$function$;

create or replace function public.admin_get_inventory_adjustments_period(
  p_start timestamp with time zone,
  p_end timestamp with time zone
)
returns table(
  created_at timestamp with time zone,
  local_day date,
  product_id uuid,
  product_name text,
  product_category text,
  active boolean,
  location text,
  delta integer,
  adjustment_kind text,
  reason text,
  note text,
  source text
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform public.assert_admin();
  return query
  select * from public.get_inventory_adjustments_period(p_start, p_end);
end;
$function$;

do $migration$
declare
  v_lot record;
  v_product record;
begin
  for v_lot in
    select
      l.id,
      l.product_id,
      l.remaining_quantity,
      l.unit_cost_cents
    from public.product_purchase_lots l
    where l.source_reason = 'purchase'
      and l.remaining_quantity > 0
    order by l.created_at asc, l.id asc
  loop
    perform public.settle_fallback_allocations_with_purchase_lot(
      v_lot.product_id,
      v_lot.id,
      v_lot.remaining_quantity,
      v_lot.unit_cost_cents
    );
  end loop;

  for v_product in select p.id from public.products p loop
    perform public.refresh_product_inventory_value_from_lots(v_product.id);
  end loop;
end;
$migration$;

notify pgrst, 'reload schema';

