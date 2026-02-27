-- Inventory count workflow:
-- 1) Snapshot without period (booked target/Soll by location)
-- 2) Apply counted Ist values as count_adjustment movements
-- 3) Period report for shortages/overstocks and adjustments

create or replace function public.admin_apply_inventory_count(
  p_items jsonb,
  p_note text default null
)
returns table(
  product_id uuid,
  name text,
  soll_warehouse_stock integer,
  ist_warehouse_stock integer,
  delta_warehouse integer,
  soll_fridge_stock integer,
  ist_fridge_stock integer,
  delta_fridge integer
)
language plpgsql
security definer
as $function$
declare
  v_wh uuid;
  v_fr uuid;
  v_item record;
  v_product record;
  v_stock record;
  v_ist_wh integer;
  v_ist_fr integer;
  v_delta_wh integer;
  v_delta_fr integer;
begin
  perform public.assert_admin();

  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items must be a json array';
  end if;

  v_wh := public.get_stock_location_id('warehouse');
  v_fr := public.get_stock_location_id('fridge');
  if v_wh is null or v_fr is null then
    raise exception 'Stock locations are not configured';
  end if;

  for v_item in
    select *
    from jsonb_to_recordset(p_items) as x(
      product_id uuid,
      ist_warehouse_stock integer,
      ist_fridge_stock integer
    )
  loop
    if v_item.product_id is null then
      raise exception 'product_id is required';
    end if;
    if v_item.ist_warehouse_stock is null or v_item.ist_fridge_stock is null then
      raise exception 'ist_warehouse_stock and ist_fridge_stock are required';
    end if;
    if v_item.ist_warehouse_stock < 0 or v_item.ist_fridge_stock < 0 then
      raise exception 'Ist stock cannot be negative';
    end if;

    select p.id, p.name
    into v_product
    from public.products p
    where p.id = v_item.product_id
      and p.inventoried = true
    limit 1;

    if v_product.id is null then
      raise exception 'Inventoried product not found: %', v_item.product_id;
    end if;

    select warehouse_qty, fridge_qty
    into v_stock
    from public.get_product_stock(v_item.product_id);

    v_ist_wh := v_item.ist_warehouse_stock;
    v_ist_fr := v_item.ist_fridge_stock;
    v_delta_wh := v_ist_wh - coalesce(v_stock.warehouse_qty, 0);
    v_delta_fr := v_ist_fr - coalesce(v_stock.fridge_qty, 0);

    if v_delta_wh <> 0 then
      insert into public.inventory_movements (
        product_id,
        quantity,
        from_location_id,
        to_location_id,
        reason,
        note,
        created_by,
        meta
      ) values (
        v_item.product_id,
        abs(v_delta_wh),
        case when v_delta_wh < 0 then v_wh else null end,
        case when v_delta_wh > 0 then v_wh else null end,
        'count_adjustment',
        coalesce(p_note, 'Inventurabgleich Lager'),
        auth.uid(),
        jsonb_build_object(
          'source', 'inventory_count',
          'location', 'warehouse',
          'expected', coalesce(v_stock.warehouse_qty, 0),
          'counted', v_ist_wh,
          'delta', v_delta_wh
        )
      );
    end if;

    if v_delta_fr <> 0 then
      insert into public.inventory_movements (
        product_id,
        quantity,
        from_location_id,
        to_location_id,
        reason,
        note,
        created_by,
        meta
      ) values (
        v_item.product_id,
        abs(v_delta_fr),
        case when v_delta_fr < 0 then v_fr else null end,
        case when v_delta_fr > 0 then v_fr else null end,
        'count_adjustment',
        coalesce(p_note, 'Inventurabgleich Kuehlschrank'),
        auth.uid(),
        jsonb_build_object(
          'source', 'inventory_count',
          'location', 'fridge',
          'expected', coalesce(v_stock.fridge_qty, 0),
          'counted', v_ist_fr,
          'delta', v_delta_fr
        )
      );
    end if;

    product_id := v_item.product_id;
    name := v_product.name;
    soll_warehouse_stock := coalesce(v_stock.warehouse_qty, 0);
    ist_warehouse_stock := v_ist_wh;
    delta_warehouse := v_delta_wh;
    soll_fridge_stock := coalesce(v_stock.fridge_qty, 0);
    ist_fridge_stock := v_ist_fr;
    delta_fridge := v_delta_fr;
    return next;
  end loop;

  return;
end;
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
as $function$
with
  loc as (
    select
      public.get_stock_location_id('warehouse') as wh_id,
      public.get_stock_location_id('fridge') as fr_id
  )
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
    case
      when im.to_location_id is not null then im.quantity
      else 0
    end
    -
    case
      when im.from_location_id is not null then im.quantity
      else 0
    end
  )::int as delta,
  case
    when (
      case
        when im.to_location_id is not null then im.quantity
        else 0
      end
      -
      case
        when im.from_location_id is not null then im.quantity
        else 0
      end
    ) < 0 then 'fehlbestand'
    when (
      case
        when im.to_location_id is not null then im.quantity
        else 0
      end
      -
      case
        when im.from_location_id is not null then im.quantity
        else 0
      end
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
order by im.created_at desc;
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
as $function$
begin
  perform public.assert_admin();
  return query
  select * from public.get_inventory_adjustments_period(p_start, p_end);
end;
$function$;

drop function if exists public.admin_get_inventory_snapshot();

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
as $function$
with
  loc as (
    select
      public.get_stock_location_id('warehouse') as wh_id,
      public.get_stock_location_id('fridge') as fr_id
  ),
  mv_total as (
    select
      im.product_id,
      coalesce(sum(
        case
          when im.to_location_id = loc.wh_id then im.quantity
          when im.from_location_id = loc.wh_id then -im.quantity
          else 0
        end
      ), 0)::int as soll_warehouse_stock,
      coalesce(sum(
        case
          when im.to_location_id = loc.fr_id then im.quantity
          when im.from_location_id = loc.fr_id then -im.quantity
          else 0
        end
      ), 0)::int as soll_fridge_stock
    from public.inventory_movements im
    cross join loc
    group by im.product_id
  )
select
  p.id as product_id,
  p.name as name,
  p.category as category,
  p.active as active,
  coalesce(mv_total.soll_warehouse_stock, 0)::int as soll_warehouse_stock,
  coalesce(mv_total.soll_fridge_stock, 0)::int as soll_fridge_stock,
  (coalesce(mv_total.soll_warehouse_stock, 0) + coalesce(mv_total.soll_fridge_stock, 0))::int as soll_total_stock
from public.products p
left join mv_total on mv_total.product_id = p.id
where p.inventoried = true
order by p.active desc, p.category, p.name;
$function$;

create or replace function public.admin_get_inventory_snapshot()
returns table(
  product_id uuid,
  name text,
  category text,
  active boolean,
  soll_warehouse_stock integer,
  soll_fridge_stock integer,
  soll_total_stock integer
)
language plpgsql
security definer
as $function$
begin
  perform public.assert_admin();
  return query
  select * from public.get_inventory_snapshot();
end;
$function$;

revoke all on function public.get_inventory_snapshot() from public;

revoke all on function public.admin_get_inventory_snapshot() from public;
grant execute on function public.admin_get_inventory_snapshot() to authenticated;

revoke all on function public.admin_apply_inventory_count(jsonb, text) from public;
grant execute on function public.admin_apply_inventory_count(jsonb, text) to authenticated;

revoke all on function public.get_inventory_adjustments_period(timestamp with time zone, timestamp with time zone) from public;

revoke all on function public.admin_get_inventory_adjustments_period(timestamp with time zone, timestamp with time zone) from public;
grant execute on function public.admin_get_inventory_adjustments_period(timestamp with time zone, timestamp with time zone) to authenticated;
